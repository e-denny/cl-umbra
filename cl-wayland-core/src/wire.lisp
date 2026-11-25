;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; Wayland wire format: framing and the argument codec.
;;;;
;;;; A message is
;;;;
;;;;     u32 object id
;;;;     u32 (size << 16) | opcode
;;;;     arguments, in interface declaration order
;;;;
;;;; where size counts the 8-byte header and is a multiple of 4.  Byte order is
;;;; the host's: Wayland connections are local, both ends are the same machine,
;;;; so there is nothing to negotiate and nothing to swap.
;;;;
;;;; This file has no I/O and no protocol knowledge.  Sockets, the 28-fd flush
;;;; ceiling and object tables arrive in later phase-0 tasks; see
;;;; docs/protocol-layer.md §1-§2 and docs/testing.md §3.

(in-package #:wayland.wire)

;;; ---------------------------------------------------------------------------
;;; Constants
;;; ---------------------------------------------------------------------------

(defconstant +header-size+ 8
  "Octets of header in front of every message.")

(defparameter *max-message-size* 65532
  "Largest single message we accept, header included (docs/protocol-layer.md §1).
A message larger than this is a protocol error, not an allocation request.

The wire's own limit is tighter than the 64 KiB the plan asks for: the size field
is 16 bits, so no message can exceed 65535 octets, and sizes are multiples of 4,
so 65532 is the largest that can exist at all.  Keeping the cap as a parameter
lets a server tighten it per connection without touching the codec.")

(defconstant +max-fds-per-flush+ 28
  "File descriptors that fit in libwayland's 128-octet ancillary buffer.
The encoder refuses to queue more than this; the I/O layer must flush instead.")

;;; ---------------------------------------------------------------------------
;;; Conditions
;;; ---------------------------------------------------------------------------

(define-condition wire-error (error)
  ((format-control
    :initarg :format-control
    :initform "wire format error"
    :reader wire-error-format-control)
   (format-arguments
    :initarg :format-arguments
    :initform '()
    :reader wire-error-format-arguments))
  (:report (lambda (condition stream)
             (apply #'format stream
                    (wire-error-format-control condition)
                    (wire-error-format-arguments condition)))))

(defmacro define-wire-error (name (parent) format-control)
  "Define a WIRE-ERROR subtype with a default report."
  `(define-condition ,name (,parent)
     ((format-control :initform ,format-control))))

;; Our own bug: a caller handed us something the format cannot express.
(define-wire-error encode-error (wire-error)
  "cannot encode value")
(define-wire-error value-out-of-range (encode-error)
  "value out of range for its wire type")

;; Neither side's fault in particular.
(define-wire-error message-too-large (wire-error)
  "message exceeds the accepted maximum size")
(define-wire-error unsupported-host-endianness (wire-error)
  "this host is not little-endian; the wire codec assumes little-endian")

;; The peer's fault.  In a server these become protocol errors and the
;; connection is dropped; they must never reach the debugger.
(define-wire-error decode-error (wire-error)
  "malformed message from peer")
(define-wire-error truncated-message (decode-error)
  "message is shorter than its arguments require")
(define-wire-error invalid-message-header (decode-error)
  "invalid message header")
(define-wire-error invalid-string (decode-error)
  "invalid string argument")
(define-wire-error invalid-array (decode-error)
  "invalid array argument")
(define-wire-error missing-fd (decode-error)
  "message declares a file descriptor that did not arrive")

;;; ---------------------------------------------------------------------------
;;; Host byte order
;;; ---------------------------------------------------------------------------

(defun host-little-endian-p ()
  "True when this host stores integers little-endian, like every Wayland peer
we will ever meet.  Checked once at load time rather than assumed, because a
silently byte-swapped codec is invisible until something subtle breaks."
  #+sbcl
  (let ((octets (make-array 4 :element-type '(unsigned-byte 8)
                              :initial-element 0)))
    (setf (aref octets 0) 1)
    (= 1 (sb-sys:with-pinned-objects (octets)
           (sb-sys:sap-ref-32 (sb-sys:vector-sap octets) 0))))
  #-sbcl
  t)

(eval-when (:load-toplevel :execute)
  (unless (host-little-endian-p)
    (error 'unsupported-host-endianness
           :format-control
           "this host is big-endian; ~A assumes little-endian like libwayland"
           :format-arguments (list "wayland.wire"))))

;;; ---------------------------------------------------------------------------
;;; Octet helpers
;;; ---------------------------------------------------------------------------

(declaim (inline load-u32))
(defun load-u32 (octets offset)
  "Read a little-endian u32 from OCTETS at OFFSET."
  (logior (aref octets offset)
          (ash (aref octets (+ offset 1)) 8)
          (ash (aref octets (+ offset 2)) 16)
          (ash (aref octets (+ offset 3)) 24)))

(declaim (inline store-u32-at))
(defun store-u32-at (octets offset value)
  "Write VALUE as a little-endian u32 at OFFSET.  Does not move a fill pointer."
  (setf (aref octets offset) (ldb (byte 8 0) value)
        (aref octets (+ offset 1)) (ldb (byte 8 8) value)
        (aref octets (+ offset 2)) (ldb (byte 8 16) value)
        (aref octets (+ offset 3)) (ldb (byte 8 24) value))
  value)

(defun pad4 (n)
  "Smallest multiple of 4 that is greater than or equal to N."
  (logand (+ n 3) (lognot 3)))

;;; ---------------------------------------------------------------------------
;;; Range checks (encode side)
;;; ---------------------------------------------------------------------------

(defun check-signed-32 (value what)
  (unless (typep value '(signed-byte 32))
    (error 'value-out-of-range
           :format-control "~A must be a signed 32-bit integer, got ~S"
           :format-arguments (list what value)))
  value)

(defun check-unsigned-32 (value what)
  (unless (typep value '(unsigned-byte 32))
    (error 'value-out-of-range
           :format-control "~A must be an unsigned 32-bit integer, got ~S"
           :format-arguments (list what value)))
  value)

(defun check-object-id (value what)
  (unless (and (typep value '(unsigned-byte 32)) (plusp value))
    (error 'value-out-of-range
           :format-control "~A must be a non-zero 32-bit object id, got ~S"
           :format-arguments (list what value)))
  value)

;;; ---------------------------------------------------------------------------
;;; The message buffer (encode side)
;;; ---------------------------------------------------------------------------

(defstruct (message-buffer (:constructor %make-message-buffer))
  (octets #() :type (array (unsigned-byte 8) (*)))
  ;; Most recently queued descriptor first; callers see BUFFER-FDS in order.
  (fds '() :type list))

(defun make-message-buffer (&key (capacity 256))
  "A fresh, empty outbound buffer.  CAPACITY is a growth hint, not a limit."
  (%make-message-buffer
   :octets (make-array capacity
                      :element-type '(unsigned-byte 8)
                      :adjustable t
                      :fill-pointer 0)))

(defun buffer-octets (buffer)
  "The buffer's octet vector.  Its fill pointer is the number of valid octets."
  (message-buffer-octets buffer))

(defun buffer-size (buffer)
  "Number of octets written so far, including any header placeholders."
  (fill-pointer (message-buffer-octets buffer)))

(defun buffer-fds (buffer)
  "Queued descriptors, in the order their arguments appeared."
  (reverse (message-buffer-fds buffer)))

(defun buffer-fd-count (buffer)
  (length (message-buffer-fds buffer)))

(defun clear-message-buffer (buffer)
  "Discard the buffered octets and descriptors.

The caller keeps ownership of the descriptors: clearing does not close them.
The I/O layer closes what it dequeued, or hands them to their `release'."
  (setf (fill-pointer (message-buffer-octets buffer)) 0)
  (setf (message-buffer-fds buffer) nil)
  buffer)

(declaim (inline store-u8))
(defun store-u8 (buffer octet)
  (vector-push-extend octet (message-buffer-octets buffer))
  buffer)

(defun store-u32 (buffer value)
  (store-u8 buffer (ldb (byte 8 0) value))
  (store-u8 buffer (ldb (byte 8 8) value))
  (store-u8 buffer (ldb (byte 8 16) value))
  (store-u8 buffer (ldb (byte 8 24) value))
  buffer)

(defun begin-message (buffer object-id opcode)
  "Start a message to OBJECT-ID with OPCODE, returning its start offset.

The size field is provisional (8) until END-MESSAGE patches it, so several
messages may share one buffer and be flushed with a single writev."
  (check-object-id object-id 'object-id)
  (unless (typep opcode '(unsigned-byte 16))
    (error 'value-out-of-range
           :format-control "opcode must be a 16-bit unsigned integer, got ~S"
           :format-arguments (list opcode)))
  (let ((start (buffer-size buffer)))
    (store-u32 buffer object-id)
    (store-u32 buffer (logior (ash +header-size+ 16) opcode))
    start))

(defun end-message (buffer start)
  "Close the message begun at START; return its final size in octets."
  (let* ((octets (message-buffer-octets buffer))
         (size (- (buffer-size buffer) start))
         (word (load-u32 octets (+ start 4))))
    (unless (<= +header-size+ size)
      (error 'encode-error
             :format-control "message at ~D is only ~D octets; the header alone is ~D"
             :format-arguments (list start size +header-size+)))
    (unless (zerop (logand size 3))
      ;; Unreachable if every writer pads, which is exactly why it is asserted:
      ;; a new argument writer that forgets padding must fail here, loudly.
      (error 'encode-error
             :format-control "message at ~D is ~D octets, not a multiple of 4"
             :format-arguments (list start size)))
    (when (> size *max-message-size*)
      (error 'message-too-large
             :format-control "message at ~D is ~D octets; the maximum is ~D"
             :format-arguments (list start size *max-message-size*)))
    (store-u32-at octets (+ start 4)
                  (logior (ash size 16) (logand word #xFFFF)))
    size))

;;; ---------------------------------------------------------------------------
;;; Argument writers
;;; ---------------------------------------------------------------------------

(defun put-int (buffer value)
  "i32"
  (store-u32 buffer (check-signed-32 value 'int))
  buffer)

(defun put-uint (buffer value)
  "u32"
  (store-u32 buffer (check-unsigned-32 value 'uint))
  buffer)

(defun fixed-to-rational (wire-value)
  "Signed 24.8 fixed point to an exact rational."
  (/ wire-value 256))

(defun rational-to-fixed (value)
  "Exact rational (or float) to signed 24.8, rounding half away from zero as
libwayland's wl_fixed_from_double does."
  (let ((scaled (* value 256)))
    (truncate (if (minusp scaled)
                  (- scaled 1/2)
                  (+ scaled 1/2)))))

(defun put-fixed (buffer value)
  "fixed: signed 24.8, carried in 4 octets."
  (store-u32 buffer (check-signed-32 (rational-to-fixed value) 'fixed))
  buffer)

(defun put-string (buffer value)
  "string: u32 length including the terminating NUL, bytes, NUL, pad to 4.

NIL is the wire's null string (length 0) and is distinct from \"\" (length 1,
a lone NUL).  Callers that round-trip a null string must use NIL, not \"\"."
  (etypecase value
    (null (store-u32 buffer 0))
    (string
     (let* ((octets (string-to-utf8 value))
            (length (1+ (length octets))))
       (store-u32 buffer length)
       (loop for octet across octets do (store-u8 buffer octet))
       (store-u8 buffer 0)
       (loop repeat (- (pad4 length) length) do (store-u8 buffer 0)))))
  buffer)

(defun put-object (buffer id)
  "object: u32 id, 0 meaning null.  NIL encodes as 0; a real id must be non-zero."
  (store-u32 buffer (if id (check-object-id id 'object) 0))
  buffer)

(defun put-new-id (buffer id)
  "new_id: like object, but the id is allocated by the sender and cannot be null."
  (store-u32 buffer (check-object-id id 'new-id))
  buffer)

(defun put-array (buffer octets)
  "array: u32 byte length, bytes, pad to 4.  NIL and an empty array both encode
as length 0; the format cannot distinguish them."
  (etypecase octets
    (null (store-u32 buffer 0))
    ((array (unsigned-byte 8) (*))
     (let ((length (length octets)))
       (store-u32 buffer length)
       (loop for octet across octets do (store-u8 buffer octet))
       (loop repeat (- (pad4 length) length) do (store-u8 buffer 0)))))
  buffer)

(defun put-fd (buffer fd)
  "fd: a 4-octet placeholder in the stream; the descriptor travels in SCM_RIGHTS.

The wire format cannot express a null descriptor -- neither does the protocol
XML, which has no nullable fd argument -- so FD must be a real one.  Queueing more than
+MAX-FDS-PER-FLUSH+ descriptors in one buffer is an error: the I/O layer must
flush at the ceiling, as libwayland does, so our batching matches everyone
else's."
  (unless (typep fd '(integer 0 #.most-positive-fixnum))
    (error 'value-out-of-range
           :format-control "fd must be a non-negative fixnum, got ~S"
           :format-arguments (list fd)))
  (when (>= (buffer-fd-count buffer) +max-fds-per-flush+)
    (error 'encode-error
           :format-control
           "~D descriptors already queued; flush before queueing more"
           :format-arguments (list +max-fds-per-flush+)))
  (push fd (message-buffer-fds buffer))
  (store-u32 buffer 0)
  buffer)

;;; ---------------------------------------------------------------------------
;;; UTF-8 (decode is lenient, encode is exact)
;;; ---------------------------------------------------------------------------

(defun string-to-utf8 (string)
  "Encode STRING as UTF-8 octets.  Signals ENCODE-ERROR above U+10FFFF."
  (let ((out (make-array (length string)
                         :element-type '(unsigned-byte 8)
                         :adjustable t
                         :fill-pointer 0)))
    (loop for character across string
          for code = (char-code character)
          do (cond
               ((< code #x80)
                (vector-push-extend code out))
               ((< code #x800)
                (vector-push-extend (logior #xC0 (ash code -6)) out)
                (vector-push-extend (logior #x80 (logand code #x3F)) out))
               ((< code #x10000)
                (vector-push-extend (logior #xE0 (ash code -12)) out)
                (vector-push-extend (logior #x80 (logand (ash code -6) #x3F)) out)
                (vector-push-extend (logior #x80 (logand code #x3F)) out))
               ((<= code #x10FFFF)
                (vector-push-extend (logior #xF0 (ash code -18)) out)
                (vector-push-extend (logior #x80 (logand (ash code -12) #x3F)) out)
                (vector-push-extend (logior #x80 (logand (ash code -6) #x3F)) out)
                (vector-push-extend (logior #x80 (logand code #x3F)) out))
               (t
                (error 'encode-error
                       :format-control "~S encodes to U+~X, beyond the UTF-8 range"
                       :format-arguments (list character code)))))
    out))

(declaim (inline continuation-octet-p))
(defun continuation-octet-p (octet)
  (= (logand octet #xC0) #x80))

(defun utf8-to-string (octets start end)
  "Decode OCTETS[START:END] as UTF-8.

Lenient by design: a malformed sequence becomes U+FFFD and decoding continues,
because a peer sending bad bytes must produce a protocol error we choose, not a
condition thrown from deep inside a decoder.  Overlong forms are accepted and
decoded as their numeric value."
  (declare (type (array (unsigned-byte 8) (*)) octets)
           (type fixnum start end))
  (let ((out (make-array (max 0 (- end start))
                         :element-type 'character
                         :adjustable t
                         :fill-pointer 0)))
    (flet ((emit (code) (vector-push-extend (code-char code) out))
           (bail () (vector-push-extend (code-char #xFFFD) out)))
      (loop with i of-type fixnum = start
            while (< i end)
            for b of-type (unsigned-byte 8) = (aref octets i)
            do (cond
                 ((< b #x80)
                  (emit b)
                  (incf i))
                 ((= (logand b #xE0) #xC0)
                  (if (and (< (1+ i) end)
                           (continuation-octet-p (aref octets (1+ i))))
                      (progn
                        (emit (logior (ash (logand b #x1F) 6)
                                      (logand (aref octets (1+ i)) #x3F)))
                        (incf i 2))
                      (progn (bail) (incf i))))
                 ((= (logand b #xF0) #xE0)
                  (if (and (< (+ i 2) end)
                           (continuation-octet-p (aref octets (+ i 1)))
                           (continuation-octet-p (aref octets (+ i 2))))
                      (progn
                        (emit (logior (ash (logand b #x0F) 12)
                                      (ash (logand (aref octets (+ i 1)) #x3F) 6)
                                      (logand (aref octets (+ i 2)) #x3F)))
                        (incf i 3))
                      (progn (bail) (incf i))))
                 ((= (logand b #xF8) #xF0)
                  (if (and (< (+ i 3) end)
                           (continuation-octet-p (aref octets (+ i 1)))
                           (continuation-octet-p (aref octets (+ i 2)))
                           (continuation-octet-p (aref octets (+ i 3))))
                      (let ((code (logior (ash (logand b #x07) 18)
                                          (ash (logand (aref octets (+ i 1)) #x3F) 12)
                                          (ash (logand (aref octets (+ i 2)) #x3F) 6)
                                          (logand (aref octets (+ i 3)) #x3F))))
                        (if (<= code #x10FFFF)
                            (progn (emit code) (incf i 4))
                            (progn (bail) (incf i))))
                      (progn (bail) (incf i))))
                 (t
                  (bail)
                  (incf i)))))
    (coerce out 'simple-string)))

;;; ---------------------------------------------------------------------------
;;; Header decoding
;;; ---------------------------------------------------------------------------

(defun decode-header (octets &key (start 0) (end (length octets)))
  "Decode the message header at START.

Returns (values object-id opcode size), where SIZE counts the header, or NIL
when fewer than 8 octets are available -- a partial message is not an error.
Header fields that cannot be true of any message signal DECODE-ERROR."
  (let ((available (- end start)))
    (when (< available +header-size+)
      (return-from decode-header nil))
    (let* ((object-id (load-u32 octets start))
           (word (load-u32 octets (+ start 4)))
           (size (ash word -16))
           (opcode (logand word #xFFFF)))
      (when (zerop object-id)
        (error 'invalid-message-header
               :format-control "message at ~D names object id 0, which is never valid"
               :format-arguments (list start)))
      (when (< size +header-size+)
        (error 'invalid-message-header
               :format-control "message at ~D declares ~D octets; the header alone is ~D"
               :format-arguments (list start size +header-size+)))
      (when (logtest size 3)
        (error 'invalid-message-header
               :format-control "message at ~D declares ~D octets, not a multiple of 4"
               :format-arguments (list start size)))
      (when (> size *max-message-size*)
        (error 'message-too-large
               :format-control "message at ~D declares ~D octets; the maximum is ~D"
               :format-arguments (list start size *max-message-size*)))
      (values object-id opcode size))))

;;; ---------------------------------------------------------------------------
;;; The reader (decode side)
;;; ---------------------------------------------------------------------------

(defstruct (reader (:constructor %make-reader (octets position end fds)))
  (octets #() :type (array (unsigned-byte 8) (*)))
  (position 0 :type fixnum)
  (end 0 :type fixnum)
  ;; Descriptors that arrived with this batch, consumed in argument order.
  (fds #() :type simple-vector)
  (fd-index 0 :type fixnum))

(defun make-reader (octets &key (start 0) (end (length octets)) (fds #()))
  "A reader over OCTETS[START:END], consuming FDS on demand."
  (unless (<= 0 start end (length octets))
    (error 'encode-error
           :format-control "reader bounds ~D..~D do not fit an octet vector of length ~D"
           :format-arguments (list start end (length octets))))
  (%make-reader octets start end (coerce fds 'simple-vector)))

(defun reader-remaining (reader)
  (- (reader-end reader) (reader-position reader)))

(defun reader-done-p (reader)
  (>= (reader-position reader) (reader-end reader)))

(defun reader-fds-consumed (reader)
  "How many descriptors the decoded arguments claimed.  Fewer than arrived means
surplus descriptors, which the caller must close."
  (reader-fd-index reader))

(defun need (reader octets)
  (when (> (+ (reader-position reader) octets) (reader-end reader))
    (error 'truncated-message
           :format-control
           "argument needs ~D octet~:P at offset ~D but only ~D remain"
           :format-arguments (list octets (reader-position reader)
                                   (reader-remaining reader))))
  reader)

(defun read-uint (reader)
  "u32"
  (need reader 4)
  (prog1 (load-u32 (reader-octets reader) (reader-position reader))
    (incf (reader-position reader) 4)))

(defun read-int (reader)
  "i32"
  (let ((value (read-uint reader)))
    (if (logbitp 31 value)
        (- value #x100000000)
        value)))

(defun read-fixed (reader)
  "fixed, as an exact rational"
  (fixed-to-rational (read-int reader)))

(defun read-string (reader)
  "string, or NIL for the null string.  Validates length, NUL terminator and
padding bounds; a string with an embedded NUL keeps it, since the length is
authoritative."
  (let ((length (read-uint reader)))
    (when (zerop length)
      (return-from read-string nil))
    (need reader (pad4 length))
    (let* ((octets (reader-octets reader))
           (start (reader-position reader))
           (last (1- (+ start length))))
      (unless (zerop (aref octets last))
        (error 'invalid-string
               :format-control
               "string at offset ~D declares ~D octets but does not end in NUL"
               :format-arguments (list start length)))
      (let ((string (utf8-to-string octets start last)))
        (incf (reader-position reader) (pad4 length))
        string))))

(defun read-object (reader)
  "object: an object id, or NIL for null."
  (let ((id (read-uint reader)))
    (if (zerop id) nil id)))

(defun read-array (reader)
  "array: a fresh octet vector, or NIL for a zero-length array."
  (let ((length (read-uint reader)))
    (when (zerop length)
      (return-from read-array nil))
    (need reader (pad4 length))
    (let ((start (reader-position reader)))
      (prog1 (subseq (reader-octets reader) start (+ start length))
        (incf (reader-position reader) (pad4 length))))))

(defun read-fd (reader)
  "fd: the next descriptor that arrived with this batch, or NIL for a null fd."
  (read-uint reader)                     ; the 4-octet placeholder
  (let* ((fds (reader-fds reader))
         (index (reader-fd-index reader)))
    (cond
      ((>= index (length fds))
       (error 'missing-fd
              :format-control
              "message declares a file descriptor but only ~D arrived"
              :format-arguments (list (length fds))))
      (t
       (incf (reader-fd-index reader))
       (aref fds index)))))

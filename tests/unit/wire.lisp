;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; Byte-exact and roundtrip tests for wayland.wire.
;;;;
;;;; The byte vectors here are written out by hand on purpose: a test that
;;;; recomputes the expected bytes with the same helpers as the encoder proves
;;;; nothing.  See docs/testing.md §3.

(in-package #:cl-user)

(defpackage #:wayland.test.wire
  (:use #:cl #:rove)
  (:local-nicknames (#:wire #:wayland.wire))
  (:documentation "Tests for the Wayland wire codec."))

(in-package #:wayland.test.wire)

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun bytes (&rest octets)
  (make-array (length octets)
              :element-type '(unsigned-byte 8)
              :initial-contents octets))

(defun u32 (value)
  "Little-endian bytes of VALUE, for hand-built malformed input."
  (list (ldb (byte 8 0) value)
        (ldb (byte 8 8) value)
        (ldb (byte 8 16) value)
        (ldb (byte 8 24) value)))

(defun message-octets (&rest pieces)
  "Concatenate byte lists into one octet vector."
  (coerce (apply #'append pieces) '(vector (unsigned-byte 8))))

(defun encode (object-id opcode &optional writer)
  "Encode one message; return its buffer."
  (let ((buffer (wire:make-message-buffer)))
    (let ((start (wire:begin-message buffer object-id opcode)))
      (when writer (funcall writer buffer))
      (wire:end-message buffer start))
    buffer))

(defun read-back (buffer &key fds)
  "A reader over BUFFER's arguments, positioned just past the header."
  (wire:make-reader (wire:buffer-octets buffer)
                    :start wire:+header-size+
                    :end (wire:buffer-size buffer)
                    :fds (or fds #())))

(defun roundtrip (writer reader &key fds)
  "Encode with WRITER, decode with READER.  Returns (values value done-p reader)."
  (let ((r (read-back (encode 1 0 writer) :fds fds)))
    (values (funcall reader r) (wire:reader-done-p r) r)))

;;; ---------------------------------------------------------------------------
;;; Framing
;;; ---------------------------------------------------------------------------

(deftest header-only
  ;; size 8, opcode 0 -> (8 << 16) | 0 = #x00080000
  (ok (equalp (bytes 1 0 0 0 0 0 8 0)
            (wire:buffer-contents (encode 1 0)))))

(deftest header-size-and-opcode-share-a-word
  ;; size 12, opcode 3 -> (12 << 16) | 3 = #x000C0003
  (ok (equalp (bytes 2 0 0 0 3 0 12 0 255 255 255 255)
            (wire:buffer-contents (encode 2 3 (lambda (b) (wire:put-int b -1)))))))

(deftest header-decodes-what-it-encoded
  (multiple-value-bind (object-id opcode size)
      (wire:decode-header (wire:buffer-contents
                           (encode 7 9 (lambda (b) (wire:put-uint b 1)))))
    (ok (eql 7 object-id))
    (ok (eql 9 opcode))
    (ok (eql 12 size))))

(deftest partial-header-is-not-an-error
  ;; Seven octets is not a message yet; the caller simply waits for more.
  (ok (null (wire:decode-header (bytes 1 0 0 0 0 0 8))))
  (ok (null (wire:decode-header (bytes))))
  (ok (eql 8 (nth-value 2 (wire:decode-header (bytes 1 0 0 0 0 0 8 0))))))

(deftest two-messages-share-one-buffer
  (let ((buffer (wire:make-message-buffer)))
    (let ((start (wire:begin-message buffer 1 1)))
      (wire:put-new-id buffer 2)
      (wire:end-message buffer start))
    (let ((start (wire:begin-message buffer 2 0)))
      (wire:put-uint buffer 7)
      (wire:put-string buffer "ok")
      (wire:end-message buffer start))
    (ok (equalp (bytes 1 0 0 0   1 0 12 0   2 0 0 0
                     2 0 0 0   0 0 20 0   7 0 0 0
                     3 0 0 0   111 107 0 0)
              (wire:buffer-contents buffer)))
    (ok (eql 32 (wire:buffer-size buffer)))))

(deftest trim-buffer-shifts-the-tail-and-can-drop-fds
  (let ((buffer (encode 1 0 (lambda (b) (wire:put-fd b 9) (wire:put-int b 5)))))
    (ok (eql 12 (wire:buffer-size buffer))
        "8 header + 4 for the int: an fd adds no octets")
    (wire:trim-buffer buffer 4)
    (ok (eql 8 (wire:buffer-size buffer)))
    (ok (eql 1 (wire:buffer-fd-count buffer)) "descriptors survive a plain trim")
    (wire:trim-buffer buffer 8 :drop-fds t)
    (ok (zerop (wire:buffer-size buffer)))
    (ok (null (wire:buffer-fds buffer))))
  (ok (signals (wire:trim-buffer (encode 1 0) 99) 'wire:encode-error)))

(deftest clear-message-buffer-resets-size-and-fds
  (let ((buffer (encode 1 0 (lambda (b) (wire:put-fd b 5)))))
    (ok (eql 1 (wire:buffer-fd-count buffer)))
    (wire:clear-message-buffer buffer)
    (ok (zerop (wire:buffer-size buffer)))
    (ok (null (wire:buffer-fds buffer)))))

;;; ---------------------------------------------------------------------------
;;; Integers
;;; ---------------------------------------------------------------------------

(deftest int-boundaries
  (dolist (value '(-2147483648 -65536 -256 -1 0 1 255 256 65536 2147483647))
    (multiple-value-bind (decoded done-p)
        (roundtrip (lambda (b) (wire:put-int b value)) #'wire:read-int)
      (ok (eql value decoded))
      (ok done-p))))

(deftest uint-boundaries
  (dolist (value '(0 1 255 256 65535 65536 2147483647 2147483648 4294967295))
    (multiple-value-bind (decoded done-p)
        (roundtrip (lambda (b) (wire:put-uint b value)) #'wire:read-uint)
      (ok (eql value decoded))
      (ok done-p))))

(deftest int-encoding-is-little-endian
  (ok (equalp (bytes 1 0 0 0 0 0 12 0 1 0 0 0)
            (wire:buffer-contents (encode 1 0 (lambda (b) (wire:put-int b 1))))))
  ;; #x12345678, low octet first.
  (ok (equalp (bytes 120 86 52 18)
            (subseq (wire:buffer-contents
                     (encode 1 0 (lambda (b) (wire:put-uint b #x12345678))))
                    8))))

(deftest int-rejects-out-of-range
  (ok (signals (wire:put-int (wire:make-message-buffer) 2147483648) 'wire:value-out-of-range))
  (ok (signals (wire:put-int (wire:make-message-buffer) -2147483649) 'wire:value-out-of-range))
  (ok (signals (wire:put-uint (wire:make-message-buffer) -1) 'wire:value-out-of-range))
  (ok (signals (wire:put-uint (wire:make-message-buffer) 4294967296) 'wire:value-out-of-range))
  (ok (signals (wire:put-int (wire:make-message-buffer) 1.5) 'wire:value-out-of-range)))

(deftest begin-message-rejects-bad-headers
  (ok (signals (wire:begin-message (wire:make-message-buffer) 0 0) 'wire:value-out-of-range))
  (ok (signals (wire:begin-message (wire:make-message-buffer) 1 65536) 'wire:value-out-of-range))
  (ok (signals (wire:begin-message (wire:make-message-buffer) 1 -1) 'wire:value-out-of-range)))

;;; ---------------------------------------------------------------------------
;;; Fixed point
;;; ---------------------------------------------------------------------------

(deftest fixed-encoding
  ;; 3/2 * 256 = 384 = #x180
  (ok (equalp (bytes 128 1 0 0)
            (subseq (wire:buffer-contents
                     (encode 1 0 (lambda (b) (wire:put-fixed b 3/2))))
                    8)))
  ;; -3/2 * 256 = -384 = #xFFFFFE80
  (ok (equalp (bytes 128 254 255 255)
            (subseq (wire:buffer-contents
                     (encode 1 0 (lambda (b) (wire:put-fixed b -3/2))))
                    8)))
  (ok (eql 3/2 (wire:fixed-to-rational 384))))

(deftest fixed-boundaries
  (dolist (value '(0 1/256 -1/256 1/2 -1/2 255/256 -255/256
                   8388607/256 -8388608/256))
    (multiple-value-bind (decoded done-p)
        (roundtrip (lambda (b) (wire:put-fixed b value)) #'wire:read-fixed)
      (ok (= value decoded))
      (ok done-p)))
  ;; Rounding matches libwayland: half away from zero.
  (ok (eql 1 (wire::rational-to-fixed 1/512)))
  (ok (eql -1 (wire::rational-to-fixed -1/512))))

;;; ---------------------------------------------------------------------------
;;; Strings
;;; ---------------------------------------------------------------------------

(deftest string-encoding
  ;; "wl": 3 octets including the NUL, one pad octet.
  (ok (equalp (bytes 3 0 0 0 119 108 0 0)
            (subseq (wire:buffer-contents
                     (encode 1 0 (lambda (b) (wire:put-string b "wl"))))
                    8)))
  ;; "": one octet, the NUL, then three pad octets.  Distinct from NIL.
  (ok (equalp (bytes 1 0 0 0 0 0 0 0)
            (subseq (wire:buffer-contents
                     (encode 1 0 (lambda (b) (wire:put-string b ""))))
                    8)))
  ;; NIL: length 0 and nothing else.
  (ok (equalp (bytes 0 0 0 0)
            (subseq (wire:buffer-contents
                     (encode 1 0 (lambda (b) (wire:put-string b nil))))
                    8)))
  ;; "abcd": 5 octets, three pad octets, so the message stays 4-aligned.
  (ok (equalp (bytes 5 0 0 0 97 98 99 100 0 0 0 0)
            (subseq (wire:buffer-contents
                     (encode 1 0 (lambda (b) (wire:put-string b "abcd"))))
                    8))))

(deftest string-utf8
  ;; U+00E9 is C3 A9; with the NUL that is 3 octets, one pad octet.
  (ok (equalp (bytes 3 0 0 0 195 169 0 0)
            (subseq (wire:buffer-contents
                     (encode 1 0 (lambda (b) (wire:put-string b "é"))))
                    8))))

(deftest string-roundtrip
  (dolist (value '("" "a" "ab" "abc" "abcd" "abcde" "wl_surface" "héllo"
                   "日本語" "with spaces and	tab"))
    (multiple-value-bind (decoded done-p)
        (roundtrip (lambda (b) (wire:put-string b value)) #'wire:read-string)
      (ok (string= value decoded))
      (ok done-p)))
  (multiple-value-bind (decoded)
      (roundtrip (lambda (b) (wire:put-string b nil)) #'wire:read-string)
    (ok (null decoded)))
  (let ((long (make-string 300 :initial-element #\z)))
    (ok (string= long
                 (roundtrip (lambda (b) (wire:put-string b long))
                            #'wire:read-string)))))

(deftest string-malformed-input
  ;; Declares two octets, but the second is not a NUL terminator.
  (ok (signals (wire:read-string (wire:make-reader (bytes 2 0 0 0 65 66 0 0)))
               'wire:invalid-string))
  ;; Declares more octets than the message contains.
  (ok (signals (wire:read-string (wire:make-reader (bytes 100 0 0 0 65 0 0 0)))
               'wire:truncated-message))
  ;; Length 0xFFFFFFFF must not allocate: pad4 overflows past the message.
  (ok (signals (wire:read-string (wire:make-reader (bytes 255 255 255 255)))
               'wire:truncated-message)))

;;; ---------------------------------------------------------------------------
;;; Arrays
;;; ---------------------------------------------------------------------------

(deftest array-encoding
  (ok (equalp (bytes 5 0 0 0 1 2 3 4 5 0 0 0)
            (subseq (wire:buffer-contents
                     (encode 1 0 (lambda (b) (wire:put-array b (bytes 1 2 3 4 5)))))
                    8)))
  (ok (equalp (bytes 0 0 0 0)
            (subseq (wire:buffer-contents
                     (encode 1 0 (lambda (b) (wire:put-array b nil))))
                    8))))

(deftest array-roundtrip
  (dolist (length '(1 2 3 4 5 6 7 8 9 300 4096))
    (let ((input (make-array length :element-type '(unsigned-byte 8))))
      (dotimes (i length)
        (setf (aref input i) (mod (* i 37) 256)))
      (multiple-value-bind (decoded done-p)
          (roundtrip (lambda (b) (wire:put-array b input)) #'wire:read-array)
        (ok (equalp input decoded))
        (ok done-p))))
  ;; A zero-length array decodes as NIL; the format cannot distinguish it from
  ;; the null array.
  (ok (null (roundtrip (lambda (b) (wire:put-array b (bytes)))
                       #'wire:read-array))))

(deftest array-malformed-input
  (ok (signals (wire:read-array (wire:make-reader (bytes 100 0 0 0 1 2 3 4 5 6 7 8)))
               'wire:truncated-message)))

;;; ---------------------------------------------------------------------------
;;; Objects and descriptors
;;; ---------------------------------------------------------------------------

(deftest object-encoding
  (ok (equalp (bytes 0 0 0 0)
            (subseq (wire:buffer-contents
                     (encode 1 0 (lambda (b) (wire:put-object b nil))))
                    8)))
  (ok (equalp (bytes 7 0 0 0)
            (subseq (wire:buffer-contents
                     (encode 1 0 (lambda (b) (wire:put-object b 7))))
                    8)))
  (ok (eql 7 (roundtrip (lambda (b) (wire:put-object b 7)) #'wire:read-object)))
  (ok (null (roundtrip (lambda (b) (wire:put-object b nil)) #'wire:read-object)))
  ;; Object id 0 means null; passing it as an object is a bug, not a null.
  (ok (signals (wire:put-object (wire:make-message-buffer) 0) 'wire:value-out-of-range))
  (ok (signals (wire:put-new-id (wire:make-message-buffer) 0) 'wire:value-out-of-range)))

(deftest fd-travels-beside-the-stream
  (let ((buffer (encode 1 0 (lambda (b) (wire:put-fd b 42)))))
    ;; An fd occupies no octets at all: the message is its header...
    (ok (eql 8 (wire:buffer-size buffer))
        "libwayland's wl_shm.create_pool(new_id, fd, size) is 16 octets, not 20")
    (ok (equalp (bytes 1 0 0 0 0 0 8 0) (wire:buffer-contents buffer)))
    ;; ...and the descriptor lives only in the buffer's queue.
    (ok (equal '(42) (wire:buffer-fds buffer)))
    (let ((reader (read-back buffer :fds #(42))))
      (ok (eql 42 (wire:read-fd reader)))
      (ok (eql 1 (wire:reader-fds-consumed reader))))))

(deftest fd-order-is-argument-order
  (let* ((buffer (encode 1 0 (lambda (b) (wire:put-fd b 7) (wire:put-fd b 9))))
         (reader (read-back buffer :fds (coerce (wire:buffer-fds buffer) 'vector))))
    (ok (equal '(7 9) (wire:buffer-fds buffer)))
    (ok (eql 7 (wire:read-fd reader)))
    (ok (eql 9 (wire:read-fd reader)))
    (ok (eql 2 (wire:reader-fds-consumed reader)))))

(deftest fd-queue-ceiling
  (let ((buffer (wire:make-message-buffer)))
    (dotimes (i wire:+max-fds-per-flush+)
      (wire:put-fd buffer i))
    (ok (eql wire:+max-fds-per-flush+ (wire:buffer-fd-count buffer)))
    (ok (signals (wire:put-fd buffer 99) 'wire:encode-error)))
  (ok (signals (wire:put-fd (wire:make-message-buffer) nil) 'wire:value-out-of-range))
  (ok (signals (wire:put-fd (wire:make-message-buffer) -1) 'wire:value-out-of-range)))

(deftest fd-that-never-arrived
  (ok (signals (wire:read-fd (wire:make-reader (bytes 0 0 0 0))) 'wire:missing-fd)
      "reading an fd consumes no octets, so an empty queue is the only signal"))

(deftest fd-does-not-move-the-reader
  (let* ((buffer (encode 1 0 (lambda (b) (wire:put-fd b 3) (wire:put-uint b 7))))
         (reader (read-back buffer :fds #(3))))
    (let ((before (wire:reader-position reader)))
      (ok (eql 3 (wire:read-fd reader)))
      (ok (= before (wire:reader-position reader)) "an fd is not in the stream"))
    (ok (eql 7 (wire:read-uint reader)))
    (ok (wire:reader-done-p reader))))

;;; ---------------------------------------------------------------------------
;;; Length limits and reader bounds
;;; ---------------------------------------------------------------------------

(deftest oversized-message-is-refused-on-encode
  (ok (signals (encode 1 0 (lambda (b)
                  (wire:put-array
                   b (make-array 70000 :element-type '(unsigned-byte 8)
                                   :initial-element 0)))) 'wire:message-too-large)))

(deftest oversized-message-is-refused-on-decode
  ;; The size field is 16 bits, so the wire itself cannot describe a message
  ;; over 65535 octets; the cap matters because a server may tighten it.
  (let ((wire:*max-message-size* 32))
    (ok (signals (wire:decode-header (bytes 1 0 0 0 0 0 36 0))
                 'wire:message-too-large)))  ; size 36, aligned
  (ok (eql 36 (nth-value 2 (wire:decode-header (bytes 1 0 0 0 0 0 36 0))))))

(deftest misaligned-message-is-refused
  (ok (signals (wire:decode-header (bytes 1 0 0 0 7 0 0 0)) 'wire:invalid-message-header))
  (ok (signals (wire:decode-header (bytes 1 0 0 0 13 0 0 0)) 'wire:invalid-message-header)))

(deftest object-id-zero-is-refused
  (ok (signals (wire:decode-header (bytes 0 0 0 0 8 0 0 0)) 'wire:invalid-message-header)))

(deftest truncated-argument
  (ok (signals (wire:read-uint (wire:make-reader (bytes 1 2 3))) 'wire:truncated-message))
  (ok (signals (wire:read-uint (wire:make-reader (bytes))) 'wire:truncated-message)))

(deftest reader-bounds-are-checked
  (ok (signals (wire:make-reader (bytes 1 2 3 4) :start 2 :end 99) 'wire:encode-error)))

(deftest pad4-computes-the-alignment
  (ok (eql 0 (wire:pad4 0)))
  (ok (eql 4 (wire:pad4 1)))
  (ok (eql 4 (wire:pad4 3)))
  (ok (eql 4 (wire:pad4 4)))
  (ok (eql 8 (wire:pad4 5)))
  (ok (eql 65536 (wire:pad4 65535))))

;;; ---------------------------------------------------------------------------
;;; Property-style roundtrips over generated values
;;; ---------------------------------------------------------------------------

;; A tiny LCG, so the "random" inputs are reproducible across runs and across
;; implementations.  CL's RANDOM-STATE is not required to be stable.
(defvar *seed* 20261125)

(defun next-random (limit)
  (setf *seed* (mod (+ (* *seed* 1103515245) 12345) #x7FFFFFFF))
  (mod *seed* limit))

(defun random-int32 ()
  (- (next-random 4294967296) 2147483648))

(defun random-fixed ()
  ;; Inside signed 24.8: -(2^23)/256 .. (2^23-1)/256
  (/ (- (next-random #x00FFFFFF) #x007FFFFF) 256))

(defun random-string ()
  (let* ((alphabet "abcz ABC-_.éλ漢")
         (length (next-random 40))
         (string (make-string length)))
    (dotimes (i length string)
      (setf (char string i) (char alphabet (next-random (length alphabet)))))))

(deftest property-roundtrip
  (dotimes (i 300)
    (let ((value (random-int32)))
      (ok (eql value (roundtrip (lambda (b) (wire:put-int b value))
                                #'wire:read-int)))))
  (dotimes (i 300)
    (let ((value (next-random 4294967296)))
      (ok (eql value (roundtrip (lambda (b) (wire:put-uint b value))
                                #'wire:read-uint)))))
  (dotimes (i 200)
    (let ((value (random-fixed)))
      (ok (= value (roundtrip (lambda (b) (wire:put-fixed b value))
                              #'wire:read-fixed)))))
  (dotimes (i 200)
    (let ((value (random-string)))
      (ok (string= value (roundtrip (lambda (b) (wire:put-string b value))
                                    #'wire:read-string)))))
  (dotimes (i 100)
    (let* ((length (next-random 300))
           (input (make-array length :element-type '(unsigned-byte 8))))
      (dotimes (j length)
        (setf (aref input j) (next-random 256)))
      (if (zerop length)
          (ok (null (roundtrip (lambda (b) (wire:put-array b input))
                               #'wire:read-array)))
          (ok (equalp input (roundtrip (lambda (b) (wire:put-array b input))
                                       #'wire:read-array))))))
  ;; Every encoded message must be 4-aligned and self-consistent.
  (dotimes (i 200)
    (let* ((value (random-string))
           (buffer (encode 1 (next-random 65536)
                           (lambda (b) (wire:put-string b value)))))
      (ok (zerop (mod (wire:buffer-size buffer) 4)))
      (multiple-value-bind (object-id opcode size)
          (wire:decode-header (wire:buffer-contents buffer))
        (declare (ignore object-id opcode))
        (ok (eql size (wire:buffer-size buffer)))))))

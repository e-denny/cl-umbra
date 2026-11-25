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
  (:use #:cl #:wayland.test)
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
  (is-equal (bytes 1 0 0 0 0 0 8 0)
            (wire:buffer-contents (encode 1 0))
            :test #'equalp))

(deftest header-size-and-opcode-share-a-word
  ;; size 12, opcode 3 -> (12 << 16) | 3 = #x000C0003
  (is-equal (bytes 2 0 0 0 3 0 12 0 255 255 255 255)
            (wire:buffer-contents (encode 2 3 (lambda (b) (wire:put-int b -1))))
            :test #'equalp))

(deftest header-decodes-what-it-encoded
  (multiple-value-bind (object-id opcode size)
      (wire:decode-header (wire:buffer-contents
                           (encode 7 9 (lambda (b) (wire:put-uint b 1)))))
    (is (eql 7 object-id))
    (is (eql 9 opcode))
    (is (eql 12 size))))

(deftest partial-header-is-not-an-error
  ;; Seven octets is not a message yet; the caller simply waits for more.
  (is (null (wire:decode-header (bytes 1 0 0 0 0 0 8))))
  (is (null (wire:decode-header (bytes))))
  (is (eql 8 (nth-value 2 (wire:decode-header (bytes 1 0 0 0 0 0 8 0))))))

(deftest two-messages-share-one-buffer
  (let ((buffer (wire:make-message-buffer)))
    (let ((start (wire:begin-message buffer 1 1)))
      (wire:put-new-id buffer 2)
      (wire:end-message buffer start))
    (let ((start (wire:begin-message buffer 2 0)))
      (wire:put-uint buffer 7)
      (wire:put-string buffer "ok")
      (wire:end-message buffer start))
    (is-equal (bytes 1 0 0 0   1 0 12 0   2 0 0 0
                     2 0 0 0   0 0 20 0   7 0 0 0
                     3 0 0 0   111 107 0 0)
              (wire:buffer-contents buffer)
              :test #'equalp)
    (is (eql 32 (wire:buffer-size buffer)))))

(deftest trim-buffer-shifts-the-tail-and-can-drop-fds
  (let ((buffer (encode 1 0 (lambda (b) (wire:put-fd b 9)))))
    (is (eql 12 (wire:buffer-size buffer)))
    (wire:trim-buffer buffer 4)
    (is (eql 8 (wire:buffer-size buffer)))
    (is (equalp (bytes 0 0 12 0 0 0 0 0) (wire:buffer-contents buffer))
        "trimming keeps the tail, in place")
    (is (eql 1 (wire:buffer-fd-count buffer)) "descriptors survive a plain trim")
    (wire:trim-buffer buffer 8 :drop-fds t)
    (is (zerop (wire:buffer-size buffer)))
    (is (null (wire:buffer-fds buffer))))
  (signals wire:encode-error
    (wire:trim-buffer (encode 1 0) 99)))

(deftest clear-message-buffer-resets-size-and-fds
  (let ((buffer (encode 1 0 (lambda (b) (wire:put-fd b 5)))))
    (is (eql 1 (wire:buffer-fd-count buffer)))
    (wire:clear-message-buffer buffer)
    (is (zerop (wire:buffer-size buffer)))
    (is (null (wire:buffer-fds buffer)))))

;;; ---------------------------------------------------------------------------
;;; Integers
;;; ---------------------------------------------------------------------------

(deftest int-boundaries
  (dolist (value '(-2147483648 -65536 -256 -1 0 1 255 256 65536 2147483647))
    (multiple-value-bind (decoded done-p)
        (roundtrip (lambda (b) (wire:put-int b value)) #'wire:read-int)
      (is (eql value decoded))
      (is done-p))))

(deftest uint-boundaries
  (dolist (value '(0 1 255 256 65535 65536 2147483647 2147483648 4294967295))
    (multiple-value-bind (decoded done-p)
        (roundtrip (lambda (b) (wire:put-uint b value)) #'wire:read-uint)
      (is (eql value decoded))
      (is done-p))))

(deftest int-encoding-is-little-endian
  (is-equal (bytes 1 0 0 0 0 0 12 0 1 0 0 0)
            (wire:buffer-contents (encode 1 0 (lambda (b) (wire:put-int b 1))))
            :test #'equalp)
  ;; #x12345678, low octet first.
  (is-equal (bytes 120 86 52 18)
            (subseq (wire:buffer-contents
                     (encode 1 0 (lambda (b) (wire:put-uint b #x12345678))))
                    8)
            :test #'equalp))

(deftest int-rejects-out-of-range
  (signals wire:value-out-of-range (wire:put-int (wire:make-message-buffer) 2147483648))
  (signals wire:value-out-of-range (wire:put-int (wire:make-message-buffer) -2147483649))
  (signals wire:value-out-of-range (wire:put-uint (wire:make-message-buffer) -1))
  (signals wire:value-out-of-range (wire:put-uint (wire:make-message-buffer) 4294967296))
  (signals wire:value-out-of-range (wire:put-int (wire:make-message-buffer) 1.5)))

(deftest begin-message-rejects-bad-headers
  (signals wire:value-out-of-range (wire:begin-message (wire:make-message-buffer) 0 0))
  (signals wire:value-out-of-range (wire:begin-message (wire:make-message-buffer) 1 65536))
  (signals wire:value-out-of-range (wire:begin-message (wire:make-message-buffer) 1 -1)))

;;; ---------------------------------------------------------------------------
;;; Fixed point
;;; ---------------------------------------------------------------------------

(deftest fixed-encoding
  ;; 3/2 * 256 = 384 = #x180
  (is-equal (bytes 128 1 0 0)
            (subseq (wire:buffer-contents
                     (encode 1 0 (lambda (b) (wire:put-fixed b 3/2))))
                    8)
            :test #'equalp)
  ;; -3/2 * 256 = -384 = #xFFFFFE80
  (is-equal (bytes 128 254 255 255)
            (subseq (wire:buffer-contents
                     (encode 1 0 (lambda (b) (wire:put-fixed b -3/2))))
                    8)
            :test #'equalp)
  (is (eql 3/2 (wire:fixed-to-rational 384))))

(deftest fixed-boundaries
  (dolist (value '(0 1/256 -1/256 1/2 -1/2 255/256 -255/256
                   8388607/256 -8388608/256))
    (multiple-value-bind (decoded done-p)
        (roundtrip (lambda (b) (wire:put-fixed b value)) #'wire:read-fixed)
      (is (= value decoded))
      (is done-p)))
  ;; Rounding matches libwayland: half away from zero.
  (is (eql 1 (wire::rational-to-fixed 1/512)))
  (is (eql -1 (wire::rational-to-fixed -1/512))))

;;; ---------------------------------------------------------------------------
;;; Strings
;;; ---------------------------------------------------------------------------

(deftest string-encoding
  ;; "wl": 3 octets including the NUL, one pad octet.
  (is-equal (bytes 3 0 0 0 119 108 0 0)
            (subseq (wire:buffer-contents
                     (encode 1 0 (lambda (b) (wire:put-string b "wl"))))
                    8)
            :test #'equalp)
  ;; "": one octet, the NUL, then three pad octets.  Distinct from NIL.
  (is-equal (bytes 1 0 0 0 0 0 0 0)
            (subseq (wire:buffer-contents
                     (encode 1 0 (lambda (b) (wire:put-string b ""))))
                    8)
            :test #'equalp)
  ;; NIL: length 0 and nothing else.
  (is-equal (bytes 0 0 0 0)
            (subseq (wire:buffer-contents
                     (encode 1 0 (lambda (b) (wire:put-string b nil))))
                    8)
            :test #'equalp)
  ;; "abcd": 5 octets, three pad octets, so the message stays 4-aligned.
  (is-equal (bytes 5 0 0 0 97 98 99 100 0 0 0 0)
            (subseq (wire:buffer-contents
                     (encode 1 0 (lambda (b) (wire:put-string b "abcd"))))
                    8)
            :test #'equalp))

(deftest string-utf8
  ;; U+00E9 is C3 A9; with the NUL that is 3 octets, one pad octet.
  (is-equal (bytes 3 0 0 0 195 169 0 0)
            (subseq (wire:buffer-contents
                     (encode 1 0 (lambda (b) (wire:put-string b "é"))))
                    8)
            :test #'equalp))

(deftest string-roundtrip
  (dolist (value '("" "a" "ab" "abc" "abcd" "abcde" "wl_surface" "héllo"
                   "日本語" "with spaces and	tab"))
    (multiple-value-bind (decoded done-p)
        (roundtrip (lambda (b) (wire:put-string b value)) #'wire:read-string)
      (is (string= value decoded))
      (is done-p)))
  (multiple-value-bind (decoded)
      (roundtrip (lambda (b) (wire:put-string b nil)) #'wire:read-string)
    (is (null decoded)))
  (let ((long (make-string 300 :initial-element #\z)))
    (is (string= long
                 (roundtrip (lambda (b) (wire:put-string b long))
                            #'wire:read-string)))))

(deftest string-malformed-input
  ;; Declares two octets, but the second is not a NUL terminator.
  (signals wire:invalid-string
    (wire:read-string (wire:make-reader (bytes 2 0 0 0 65 66 0 0))))
  ;; Declares more octets than the message contains.
  (signals wire:truncated-message
    (wire:read-string (wire:make-reader (bytes 100 0 0 0 65 0 0 0))))
  ;; Length 0xFFFFFFFF must not allocate: pad4 overflows past the message.
  (signals wire:truncated-message
    (wire:read-string (wire:make-reader (bytes 255 255 255 255)))))

;;; ---------------------------------------------------------------------------
;;; Arrays
;;; ---------------------------------------------------------------------------

(deftest array-encoding
  (is-equal (bytes 5 0 0 0 1 2 3 4 5 0 0 0)
            (subseq (wire:buffer-contents
                     (encode 1 0 (lambda (b) (wire:put-array b (bytes 1 2 3 4 5)))))
                    8)
            :test #'equalp)
  (is-equal (bytes 0 0 0 0)
            (subseq (wire:buffer-contents
                     (encode 1 0 (lambda (b) (wire:put-array b nil))))
                    8)
            :test #'equalp))

(deftest array-roundtrip
  (dolist (length '(1 2 3 4 5 6 7 8 9 300 4096))
    (let ((input (make-array length :element-type '(unsigned-byte 8))))
      (dotimes (i length)
        (setf (aref input i) (mod (* i 37) 256)))
      (multiple-value-bind (decoded done-p)
          (roundtrip (lambda (b) (wire:put-array b input)) #'wire:read-array)
        (is (equalp input decoded))
        (is done-p))))
  ;; A zero-length array decodes as NIL; the format cannot distinguish it from
  ;; the null array.
  (is (null (roundtrip (lambda (b) (wire:put-array b (bytes)))
                       #'wire:read-array))))

(deftest array-malformed-input
  (signals wire:truncated-message
    (wire:read-array (wire:make-reader (bytes 100 0 0 0 1 2 3 4 5 6 7 8)))))

;;; ---------------------------------------------------------------------------
;;; Objects and descriptors
;;; ---------------------------------------------------------------------------

(deftest object-encoding
  (is-equal (bytes 0 0 0 0)
            (subseq (wire:buffer-contents
                     (encode 1 0 (lambda (b) (wire:put-object b nil))))
                    8)
            :test #'equalp)
  (is-equal (bytes 7 0 0 0)
            (subseq (wire:buffer-contents
                     (encode 1 0 (lambda (b) (wire:put-object b 7))))
                    8)
            :test #'equalp)
  (is (eql 7 (roundtrip (lambda (b) (wire:put-object b 7)) #'wire:read-object)))
  (is (null (roundtrip (lambda (b) (wire:put-object b nil)) #'wire:read-object)))
  ;; Object id 0 means null; passing it as an object is a bug, not a null.
  (signals wire:value-out-of-range
    (wire:put-object (wire:make-message-buffer) 0))
  (signals wire:value-out-of-range
    (wire:put-new-id (wire:make-message-buffer) 0)))

(deftest fd-travels-beside-the-stream
  (let ((buffer (encode 1 0 (lambda (b) (wire:put-fd b 42)))))
    ;; Four octets of placeholder in the stream...
    (is-equal (bytes 0 0 0 0)
              (subseq (wire:buffer-contents buffer) 8)
              :test #'equalp)
    ;; ...and the descriptor in the buffer's queue.
    (is (equal '(42) (wire:buffer-fds buffer)))
    (let ((reader (read-back buffer :fds #(42))))
      (is (eql 42 (wire:read-fd reader)))
      (is (eql 1 (wire:reader-fds-consumed reader))))))

(deftest fd-order-is-argument-order
  (let* ((buffer (encode 1 0 (lambda (b) (wire:put-fd b 7) (wire:put-fd b 9))))
         (reader (read-back buffer :fds (coerce (wire:buffer-fds buffer) 'vector))))
    (is (equal '(7 9) (wire:buffer-fds buffer)))
    (is (eql 7 (wire:read-fd reader)))
    (is (eql 9 (wire:read-fd reader)))
    (is (eql 2 (wire:reader-fds-consumed reader)))))

(deftest fd-queue-ceiling
  (let ((buffer (wire:make-message-buffer)))
    (dotimes (i wire:+max-fds-per-flush+)
      (wire:put-fd buffer i))
    (is (eql wire:+max-fds-per-flush+ (wire:buffer-fd-count buffer)))
    (signals wire:encode-error (wire:put-fd buffer 99)))
  (signals wire:value-out-of-range (wire:put-fd (wire:make-message-buffer) nil))
  (signals wire:value-out-of-range (wire:put-fd (wire:make-message-buffer) -1)))

(deftest fd-that-never-arrived
  (signals wire:missing-fd
    (wire:read-fd (wire:make-reader (bytes 0 0 0 0)))))

;;; ---------------------------------------------------------------------------
;;; Length limits and reader bounds
;;; ---------------------------------------------------------------------------

(deftest oversized-message-is-refused-on-encode
  (signals wire:message-too-large
    (encode 1 0 (lambda (b)
                  (wire:put-array
                   b (make-array 70000 :element-type '(unsigned-byte 8)
                                   :initial-element 0))))))

(deftest oversized-message-is-refused-on-decode
  ;; The size field is 16 bits, so the wire itself cannot describe a message
  ;; over 65535 octets; the cap matters because a server may tighten it.
  (let ((wire:*max-message-size* 32))
    (signals wire:message-too-large
      (wire:decode-header (bytes 1 0 0 0 0 0 36 0))))  ; size 36, aligned
  (is (eql 36 (nth-value 2 (wire:decode-header (bytes 1 0 0 0 0 0 36 0))))))

(deftest misaligned-message-is-refused
  (signals wire:invalid-message-header
    (wire:decode-header (bytes 1 0 0 0 7 0 0 0)))
  (signals wire:invalid-message-header
    (wire:decode-header (bytes 1 0 0 0 13 0 0 0))))

(deftest object-id-zero-is-refused
  (signals wire:invalid-message-header
    (wire:decode-header (bytes 0 0 0 0 8 0 0 0))))

(deftest truncated-argument
  (signals wire:truncated-message
    (wire:read-uint (wire:make-reader (bytes 1 2 3))))
  (signals wire:truncated-message
    (wire:read-uint (wire:make-reader (bytes)))))

(deftest reader-bounds-are-checked
  (signals wire:encode-error
    (wire:make-reader (bytes 1 2 3 4) :start 2 :end 99)))

(deftest pad4-computes-the-alignment
  (is (eql 0 (wire:pad4 0)))
  (is (eql 4 (wire:pad4 1)))
  (is (eql 4 (wire:pad4 3)))
  (is (eql 4 (wire:pad4 4)))
  (is (eql 8 (wire:pad4 5)))
  (is (eql 65536 (wire:pad4 65535))))

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
      (is (eql value (roundtrip (lambda (b) (wire:put-int b value))
                                #'wire:read-int)))))
  (dotimes (i 300)
    (let ((value (next-random 4294967296)))
      (is (eql value (roundtrip (lambda (b) (wire:put-uint b value))
                                #'wire:read-uint)))))
  (dotimes (i 200)
    (let ((value (random-fixed)))
      (is (= value (roundtrip (lambda (b) (wire:put-fixed b value))
                              #'wire:read-fixed)))))
  (dotimes (i 200)
    (let ((value (random-string)))
      (is (string= value (roundtrip (lambda (b) (wire:put-string b value))
                                    #'wire:read-string)))))
  (dotimes (i 100)
    (let* ((length (next-random 300))
           (input (make-array length :element-type '(unsigned-byte 8))))
      (dotimes (j length)
        (setf (aref input j) (next-random 256)))
      (if (zerop length)
          (is (null (roundtrip (lambda (b) (wire:put-array b input))
                               #'wire:read-array)))
          (is (equalp input (roundtrip (lambda (b) (wire:put-array b input))
                                       #'wire:read-array))))))
  ;; Every encoded message must be 4-aligned and self-consistent.
  (dotimes (i 200)
    (let* ((value (random-string))
           (buffer (encode 1 (next-random 65536)
                           (lambda (b) (wire:put-string b value)))))
      (is (zerop (mod (wire:buffer-size buffer) 4)))
      (multiple-value-bind (object-id opcode size)
          (wire:decode-header (wire:buffer-contents buffer))
        (declare (ignore object-id opcode))
        (is (eql size (wire:buffer-size buffer)))))))

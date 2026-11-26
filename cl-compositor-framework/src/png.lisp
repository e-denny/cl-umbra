;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; PNG writing for readback and golden tests.
;;;;
;;;; The smallest correct encoder: RGBA8, scanlines with filter 0, and deflate
;;;; "stored" blocks -- so no compression library, no external dependency, and an
;;;; output any viewer and any test can read.  A screenshot is a debugging
;;;; artefact; if PNG size ever matters, a real deflate is a one-function change.

(in-package #:cf.backend.headless.png)

;;; ---------------------------------------------------------------------------
;;; Checksums
;;; ---------------------------------------------------------------------------

(defparameter +crc-table+
  (let ((table (make-array 256 :element-type '(unsigned-byte 32))))
    (dotimes (index 256 table)
      (let ((value index))
        (dotimes (bit 8)
          (setf value (if (logtest value 1)
                          (logxor #xEDB88320 (ash value -1))
                          (ash value -1))))
        (setf (aref table index) (ldb (byte 32 0) value))))))

(defun crc32 (octets &key (start 0) (end (length octets)))
  "The CRC-32 PNG requires, over OCTETS[START:END]."
  (let ((crc #xFFFFFFFF))
    (loop for index from start below end
          do (setf crc (logxor (aref +crc-table+
                                     (logand #xFF (logxor crc (aref octets index))))
                               (ash crc -8))))
    (logand #xFFFFFFFF (logxor crc #xFFFFFFFF))))

(defun adler32 (octets)
  "The Adler-32 zlib requires."
  (let ((a 1) (b 0))
    (loop for octet across octets
          do (setf a (mod (+ a octet) 65521)
                   b (mod (+ b a) 65521)))
    (logior (ash b 16) a)))

;;; ---------------------------------------------------------------------------
;;; Byte plumbing
;;; ---------------------------------------------------------------------------

(defun u32-octets (value)
  "A 32-bit value big-endian: PNG chunk lengths and CRCs, and zlib's Adler-32, all
are big-endian on the wire, unlike the little-endian Wayland messages next door."
  (let ((octets (make-array 4 :element-type '(unsigned-byte 8))))
    (dotimes (index 4 octets)
      (setf (aref octets index) (ldb (byte 8 (* 8 (- 3 index))) value)))))

(defun chunk (type-octets data)
  "One PNG chunk: length, type, data, CRC over type+data."
  (let* ((type-and-data (concatenate '(vector (unsigned-byte 8)) type-octets data))
         (out (concatenate '(vector (unsigned-byte 8))
                           (u32-octets (length data))
                           type-and-data
                           (u32-octets (crc32 type-and-data)))))
    out))

(defun octets-of (string)
  (let ((octets (make-array (length string) :element-type '(unsigned-byte 8))))
    (dotimes (index (length string) octets)
      (setf (aref octets index) (char-code (char string index))))))

(defun zlib-stored (data)
  "zlib stream with stored deflate blocks: header, blocks, Adler-32."
  (let* ((blocks (ceiling (max 1 (length data)) 65535))
         (out (make-array (+ 2 (* blocks 5) (length data) 4)
                          :element-type '(unsigned-byte 8)))
         (position 2))
    (setf (aref out 0) #x78 (aref out 1) #x01)   ; CMF/FLG: deflate, 32 KiB window
    (loop for offset from 0 below (max 1 (length data)) by 65535
          for length = (min 65535 (- (length data) offset))
          do (setf (aref out position) (if (= length (- (length data) offset)) 1 0)
                   (aref out (+ position 1)) (ldb (byte 8 0) length)
                   (aref out (+ position 2)) (ldb (byte 8 8) length)
                   (aref out (+ position 3)) (ldb (byte 8 0) (logxor length #xFFFF))
                   (aref out (+ position 4)) (ldb (byte 8 8) (logxor length #xFFFF)))
             (replace out data :start1 (+ position 5) :start2 offset
                           :end2 (+ offset length))
             (incf position (+ 5 length)))
    (let ((adler (u32-octets (adler32 data))))
      (replace out adler :start1 position))
    out))

;;; ---------------------------------------------------------------------------
;;; The encoder
;;; ---------------------------------------------------------------------------

(defun write-png (path octets width height &key (stride (* width 4)))
  "Write OCTETS (ARGB8888, premultiplied, little-endian) as a PNG at PATH.

The alpha channel is kept as it is: premultiplied ARGB is what pixman produced,
and a screenshot's job is to show exactly that."
  (let* ((raw (make-array (* height (1+ (* width 4)))
                          :element-type '(unsigned-byte 8)))
         (position 0))
    ;; Scanlines: filter byte 0, then RGBA in PNG order (our memory is B,G,R,A).
    (dotimes (row height)
      (setf (aref raw position) 0)
      (incf position)
      (loop for column below width
            for source = (+ (* row stride) (* column 4))
            do (setf (aref raw position) (aref octets (+ source 2))
                     (aref raw (+ position 1)) (aref octets (+ source 1))
                     (aref raw (+ position 2)) (aref octets source)
                     (aref raw (+ position 3)) (aref octets (+ source 3)))
               (incf position 4)))
    (let* ((ihdr (concatenate '(vector (unsigned-byte 8))
                              (u32-octets width)
                              (u32-octets height)
                              #(8 6 0 0 0)))          ; 8-bit RGBA, deflate, no interlace
           (png (concatenate '(vector (unsigned-byte 8))
                             #(137 80 78 71 13 10 26 10)  ; signature
                             (chunk (octets-of "IHDR") ihdr)
                             (chunk (octets-of "IDAT") (zlib-stored raw))
                             (chunk (octets-of "IEND") #()))))
      (with-open-file (stream path :direction :output
                                   :element-type '(unsigned-byte 8)
                                   :if-exists :supersede
                                   :if-does-not-exist :create)
        (write-sequence png stream))
      path)))

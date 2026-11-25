;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The fuzzers' random source, shared by both of them.
;;;;
;;;; Not CL:RANDOM: a failure has to be reproducible from the seed alone, on any
;;;; SBCL, and the printed seed is the whole bug report.  xorshift64* is four
;;;; lines and good enough for octets.

(in-package #:cl-user)

(defpackage #:wayland.fuzz.rng
  (:use #:cl)
  (:documentation "A seeded, reproducible random source for the fuzz harnesses.")
  (:export #:make-seeded-rng
           #:rng-next
           #:rng-below
           #:rng-octets
           #:random-choice
           #:store-u32))

(in-package #:wayland.fuzz.rng)

(defstruct (rng (:constructor make-rng (state)))
  (state 12345 :type (unsigned-byte 64)))

(defun make-seeded-rng (seed)
  "A generator whose whole future is SEED.  Any nonzero 64-bit state works;
zero is a fixed point."
  (make-rng (logand #xFFFFFFFFFFFFFFFF (if (zerop seed) 88172645463325252 seed))))

(defun rng-next (rng)
  (let ((x (rng-state rng)))
    (setf x (logand #xFFFFFFFFFFFFFFFF (logxor x (ash x -12))))
    (setf x (logand #xFFFFFFFFFFFFFFFF (logxor x (ash x 25))))
    (setf x (logand #xFFFFFFFFFFFFFFFF (logxor x (ash x 27))))
    (setf (rng-state rng) x)
    (logand #xFFFFFFFFFFFFFFFF (* x #x2545F4914F6CDD1D))))

(defun rng-below (rng limit)
  "A number in [0, LIMIT)."
  (if (<= limit 1) 0 (mod (rng-next rng) limit)))

(defun rng-octets (rng count)
  (let ((octets (make-array count :element-type '(unsigned-byte 8))))
    (dotimes (index count octets)
      (setf (aref octets index) (rng-below rng 256)))))

(defun store-u32 (octets offset value)
  "Little-endian u32 at OFFSET, for hand-built or deliberately broken headers."
  (dotimes (index 4)
    (setf (aref octets (+ offset index)) (logand #xFF (ash value (* -8 index))))))

(defun random-choice (rng sequence)
  (let ((sequence (coerce sequence 'vector)))
    (and (plusp (length sequence))
         (aref sequence (rng-below rng (length sequence))))))

;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; cf.backend.libinput: classification, key naming, pointer arithmetic and what
;;;; the sink is told (D56).
;;;;
;;;; No device is opened and no context is created: everything below the RAW-EVENT
;;;; boundary is ordinary Lisp, and a test constructs the raw events a device
;;;; would have produced.  The line is deliberate -- it is the same line
;;;; cf.backend.drm draws at its six kernel calls -- because the interesting
;;;; mistakes here are not CFFI ones.  They are "the pointer teleported after a
;;;; drag off the edge", "the shifted keysym did not map back to its key", "a
;;;; scroll was delivered twice".
;;;;
;;;; What only a real device answers -- whether libinput opens an event node at
;;;; all, what the kernel calls it, which capabilities it has -- is
;;;; scripts/input-gate.lisp's business.

(in-package #:cl-user)

(defpackage #:wayland.test.libinput
  (:use #:cl #:rove)
  (:local-nicknames (#:li #:cf.backend.libinput)
                    (#:input #:cf.input))
  (:documentation "Tests for cf.backend.libinput: the decode chain below the C
boundary (D56)."))

(in-package #:wayland.test.libinput)

;;; ---------------------------------------------------------------------------
;;; Fixtures
;;; ---------------------------------------------------------------------------

(defvar *events* '()
  "The sink's recording: (kind payload) in arrival order, most recent first.")

(defun recording-driver (&key (width 800) (height 600))
  (setf *events* '())
  (li:make-input-driver
   :width width :height height
   :sink (lambda (kind payload) (push (list kind payload) *events*))))

(defun delivered (kind)
  "The payloads delivered as KIND, oldest first."
  (loop for (delivered-kind payload) in (reverse *events*)
        when (eq delivered-kind kind) collect payload))

(defun events-by-kind ()
  (mapcar #'first (reverse *events*)))

(defmacro with-driver ((variable &rest arguments) &body body)
  `(let ((,variable (recording-driver ,@arguments)))
     (unwind-protect (progn ,@body)
       (li:close-input ,variable))))

(defun raw (kind &rest arguments)
  (apply #'li:make-raw-event :kind kind arguments))

;;; ---------------------------------------------------------------------------
;;; Classification
;;; ---------------------------------------------------------------------------

(deftest every-decoded-type-has-a-kind-and-nothing-else-does
  (ok (eq :device-added (li:event-kind 1)))
  (ok (eq :device-removed (li:event-kind 2)))
  (ok (eq :keyboard-key (li:event-kind 300)))
  (ok (eq :motion (li:event-kind 400)))
  (ok (eq :motion-absolute (li:event-kind 401)))
  (ok (eq :button (li:event-kind 402)))
  (ok (eq :scroll-wheel (li:event-kind 404)))
  (ok (eq :scroll-finger (li:event-kind 405)))
  (ok (eq :scroll-continuous (li:event-kind 406)))
  (ok (null (li:event-kind 0)) "NONE is not an event")
  (ok (null (li:event-kind 403))
      "the legacy axis event is deliberately not decoded: libinput >= 1.19 also
       sends it in addition to the new scroll events, so decoding both scrolls
       twice")
  (ok (null (li:event-kind 500)) "touch is not in this slice"))

(deftest states-and-buttons-get-names
  (ok (eq :pressed (li:key-state-keyword 1)))
  (ok (eq :released (li:key-state-keyword 0)))
  (ok (eq :pressed (li:button-state-keyword 1)))
  (ok (eq :released (li:button-state-keyword 0)))
  (ok (eq :left (li:button-name #x110)))
  (ok (eq :right (li:button-name #x111)))
  (ok (eq :middle (li:button-name #x112)))
  (ok (eql #x120 (li:button-name #x120))
      "a button with no name keeps its code rather than becoming NIL")
  (ok (eq :vertical (li:axis-keyword 0)))
  (ok (eq :horizontal (li:axis-keyword 1))))

(deftest the-seat-speaks-keysym-names-not-evdev-codes
  ;; libinput reports what the kernel reports -- an evdev code -- and INJECT-KEY
  ;; takes the keysym name a keybinding table uses.  This is the join between the
  ;; two, and it is the direction that can silently produce NIL.
  (ok (equal "a" (input:key-name-for-code 30)))
  (ok (= 30 (input:keycode "a"))
      "the name found is the one KEYCODE maps back to its own code")
  (ok (equal "Shift_L" (input:key-name-for-code 42)))
  (ok (equal "Control_L" (input:key-name-for-code 29)))
  (ok (equal "Alt_L" (input:key-name-for-code 56)))
  (ok (equal "F1" (input:key-name-for-code 59)))
  (ok (equal "Escape" (input:key-name-for-code 1)))
  (ok (null (input:key-name-for-code 240))
      "KEY_UNKNOWN is in no keymap and is not an error")
  (ok (null (input:key-name-for-code nil))))

;;; ---------------------------------------------------------------------------
;;; Pointer arithmetic
;;; ---------------------------------------------------------------------------

(deftest a-coordinate-is-clamped-into-the-output
  (ok (= 0 (li:clamp-coordinate -12 800)))
  (ok (= 799 (li:clamp-coordinate 1000 800)))
  (ok (= 400 (li:clamp-coordinate 400.4 800)))
  (ok (= 0 (li:clamp-coordinate 40 nil)) "no output yet means the origin")
  (ok (= 0 (li:clamp-coordinate 40 0)) "a zero-width output cannot be entered"))

(deftest deltas-accumulate-into-a-position
  (with-driver (driver)
    (li:apply-raw-event driver (raw :motion :dx 10d0 :dy 5d0))
    (ok (= 10 (li:input-driver-pointer-x driver)))
    (ok (= 5 (li:input-driver-pointer-y driver)))
    (li:apply-raw-event driver (raw :motion :dx -3d0 :dy 2d0))
    (ok (= 7 (li:input-driver-pointer-x driver)))
    (ok (= 7 (li:input-driver-pointer-y driver)))
    (ok (= 2 (li:input-driver-motion-count driver)))
    (ok (equal '(10 7) (mapcar (lambda (p) (getf p :x)) (delivered :motion))))
    (ok (= 7 (getf (second (delivered :motion)) :x)) "the sink hears every position")))

(deftest the-pointer-does-not-wander-off-the-edge
  ;; A mouse pushed 5000 pixels past the right edge and brought back by 5 must be
  ;; at 794, not at 5794-with-a-clamp applied once: the accumulation, not just the
  ;; report, has to be clamped (D47's rule for the pointer rather than a grab).
  (with-driver (driver)
    (li:apply-raw-event driver (raw :motion :dx 5000d0 :dy 5000d0))
    (ok (= 799 (li:input-driver-pointer-x driver)))
    (ok (= 599 (li:input-driver-pointer-y driver)))
    (li:apply-raw-event driver (raw :motion :dx -5d0 :dy -5d0))
    (ok (= 794 (li:input-driver-pointer-x driver)))
    (ok (= 594 (li:input-driver-pointer-y driver)))))

(deftest an-absolute-device-sets-the-position
  (with-driver (driver)
    (li:apply-raw-event driver (raw :motion-absolute :absolute-x 123.6d0 :absolute-y 45.2d0))
    (ok (= 124 (li:input-driver-pointer-x driver)))
    (ok (= 45 (li:input-driver-pointer-y driver)))
    (li:apply-raw-event driver (raw :motion-absolute :absolute-x 9000d0 :absolute-y -3d0))
    (ok (= 799 (li:input-driver-pointer-x driver)))
    (ok (= 0 (li:input-driver-pointer-y driver)))))

;;; ---------------------------------------------------------------------------
;;; What the sink is told
;;; ---------------------------------------------------------------------------

(deftest a-key-arrives-as-its-keysym-name
  (with-driver (driver)
    (li:apply-raw-event driver (raw :keyboard-key :key 30 :key-state :pressed))
    (li:apply-raw-event driver (raw :keyboard-key :key 30 :key-state :released))
    (ok (= 2 (li:input-driver-key-count driver)))
    (ok (equal '(("a" :pressed) ("a" :released))
               (mapcar (lambda (p) (list (getf p :name) (getf p :state)))
                       (delivered :key))))
    (ok (= 30 (getf (first (delivered :key)) :code))
        "the code is kept: a log line and a debugger both want it")))

(deftest a-key-the-table-does-not-name-is-reported-not-dropped
  ;; "Nothing happened" and "there is no such key" are different reports.  A
  ;; multimedia key must not look like a broken compositor.
  (with-driver (driver)
    (li:apply-raw-event driver (raw :keyboard-key :key 240 :key-state :pressed))
    (ok (= 1 (li:input-driver-unknown-key-count driver)))
    (ok (null (delivered :key)))
    (ok (equal '((:code 240)) (delivered :unknown-key)))))

(deftest a-button-arrives-with-its-name
  (with-driver (driver)
    (li:apply-raw-event driver (raw :button :button #x110 :button-state :pressed))
    (ok (= 1 (li:input-driver-button-count driver)))
    (let ((payload (first (delivered :button))))
      (ok (eq :left (getf payload :button)))
      (ok (eq :pressed (getf payload :state)))
      (ok (= #x110 (getf payload :code))))))

(deftest a-scroll-carries-its-axis-and-value
  (with-driver (driver)
    (li:apply-raw-event driver (raw :scroll-wheel :axis :vertical :value 15d0))
    (li:apply-raw-event driver (raw :scroll-finger :axis :horizontal :value -3d0))
    (ok (= 2 (li:input-driver-axis-count driver)))
    (ok (equal '((:vertical 15d0) (:horizontal -3d0))
               (mapcar (lambda (p) (list (getf p :axis) (getf p :value)))
                       (delivered :axis))))
    (ok (equal '(:scroll-wheel :scroll-finger)
               (mapcar (lambda (p) (getf p :source)) (delivered :axis)))
        "the source stays in the payload so a caller can tell a wheel from a finger")))

(deftest devices-are-tracked-by-sysname
  (with-driver (driver)
    (li:apply-raw-event driver
                        (raw :device-added
                             :device '(:name "Virtual keyboard" :sysname "event99"
                                       :vendor 1 :product 1 :caps (:keyboard))))
    (li:apply-raw-event driver
                        (raw :device-added
                             :device '(:name "Virtual mouse" :sysname "event98"
                                       :vendor 1 :product 2 :caps (:pointer))))
    (ok (equal '("event98" "event99") (li:input-driver-device-names driver)))
    (ok (= 2 (li:input-driver-device-added-count driver)))
    (li:apply-raw-event driver
                        (raw :device-removed
                             :device '(:name "Virtual keyboard" :sysname "event99"
                                       :vendor 1 :product 1 :caps (:keyboard))))
    (ok (equal '("event98") (li:input-driver-device-names driver)))
    (ok (= 1 (li:input-driver-device-removed-count driver)))
    (ok (eq :device-added (first (events-by-kind))))))

(deftest an-undecoded-event-is-counted-and-nothing-else
  (with-driver (driver)
    (li:apply-raw-event driver (raw nil))
    (ok (= 1 (li:input-driver-ignored-count driver)))
    (ok (= 1 (li:input-driver-event-count driver))
        "it was seen and counted as ignored, which is what a touch event is")
    (ok (null (delivered :key)))))

(deftest a-sink-that-signals-does-not-stop-decoding
  (let ((driver (li:make-input-driver
                 :width 100 :height 100
                 :sink (lambda (kind payload)
                         (declare (ignore kind payload))
                         (error "sink policy failed")))))
    (unwind-protect
         (progn
           (ok (eq :key (li:apply-raw-event
                         driver (raw :keyboard-key :key 30 :key-state :pressed))))
           (ok (= 1 (length (li:input-driver-callback-errors driver))))
           (li:apply-raw-event driver (raw :keyboard-key :key 31 :key-state :pressed))
           (ok (= 2 (li:input-driver-key-count driver))))
      (li:close-input driver))))

(deftest a-driver-with-no-sink-still-decodes
  ;; MAKE-INPUT-DRIVER's default sink does nothing; the counters are then the only
  ;; evidence, which is what the gate's "did anything arrive" check reads.
  (let ((driver (li:make-input-driver :width 10 :height 10)))
    (unwind-protect
         (progn
           (li:apply-raw-event driver (raw :keyboard-key :key 30 :key-state :pressed))
           (ok (= 1 (li:input-driver-event-count driver))))
      (li:close-input driver))))

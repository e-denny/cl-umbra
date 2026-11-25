;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; A very small test harness.  Twenty lines of scaffolding is cheaper than a
;;;; dependency for phase 0, and it keeps the core systems dependency-free
;;;; (docs/testing.md §3: byte-exact vectors and roundtrips, no framework
;;;; requirements).

(in-package #:cl-user)

(defpackage #:wayland.test
  (:use #:cl)
  (:documentation "Minimal assertion and reporting harness for the test suite.")
  (:export #:deftest
           #:is
           #:is-equal
           #:signals
           #:run-all
           #:*tests*))

(in-package #:wayland.test)

(defvar *tests* '()
  "Test names, in definition order.")

(defvar *test-functions* (make-hash-table :test #'eq))

(defvar *checks* 0)
(defvar *passed* 0)
(defvar *failures* 0)
(defvar *current-test* nil)

(defun %fail (form description detail)
  (incf *failures*)
  (format *error-output* "~&  FAIL [~A]~@[ ~A:~] ~A~%         form: ~S~%"
          *current-test* description detail form))

(defmacro deftest (name &body body)
  "Define and register a test."
  `(progn
     (setf (gethash ',name *test-functions*) (lambda () ,@body))
     (unless (member ',name *tests* :test #'eq)
       (setf *tests* (append *tests* (list ',name))))
     ',name))

(defmacro is (form &optional description)
  "Check that FORM is true.  An error in FORM is a failure, not an escape."
  `(progn
     (incf *checks*)
     (handler-case
         (if ,form
             (incf *passed*)
             (%fail ',form ,description "evaluated to NIL"))
       (error (condition)
         (%fail ',form ,description
                (format nil "signalled ~A: ~A" (type-of condition) condition))))))

(defmacro is-equal (expected form &key (test ''equal) description)
  "Check that FORM equals EXPECTED under TEST.

TEST is spliced as a form, not evaluated at macroexpansion time; hence the
doubled quote in the default, so a call that does not name a test expands to
\(funcall 'equal ...) rather than to a function object a fasl cannot hold."
  `(progn
     (incf *checks*)
     (handler-case
         (let ((expected-value ,expected)
               (actual-value ,form))
           (if (funcall ,test expected-value actual-value)
               (incf *passed*)
               (%fail ',form ,description
                      (format nil "expected ~S~%              got ~S"
                              expected-value actual-value))))
       (error (condition)
         (%fail ',form ,description
                (format nil "signalled ~A: ~A" (type-of condition) condition))))))

(defmacro signals (condition-type &body body)
  "Check that BODY signals CONDITION-TYPE, and nothing else."
  `(progn
     (incf *checks*)
     (handler-case
         (progn
           ,@body
           (%fail (list 'signals ',condition-type) nil
                  "no condition was signalled"))
       (,condition-type ()
         (incf *passed*))
       (error (condition)
         (%fail (list 'signals ',condition-type) nil
                (format nil "expected ~S, got ~A: ~A"
                        ',condition-type (type-of condition) condition))))))

(defun run-all (&key (stream *standard-output*))
  "Run every registered test.  Returns 0 on success, 1 if any check failed."
  (let ((*checks* 0) (*passed* 0) (*failures* 0))
    (format stream "~&Running ~D test~:P~%" (length *tests*))
    (dolist (name *tests*)
      (let ((*current-test* name)
            (before *failures*))
        (handler-case (funcall (gethash name *test-functions*))
          (error (condition)
            (incf *failures*)
            (format *error-output* "~&  ABORT [~A] ~A~%" name condition)))
        (format stream "  ~:[FAIL~;ok  ~] ~A~%" (= before *failures*) name)))
    (format stream "~&~D check~:P, ~D passed, ~D failed~%"
            *checks* *passed* *failures*)
    (format stream "~:[FAILED~;PASSED~]~%" (zerop *failures*))
    (if (zerop *failures*) 0 1)))

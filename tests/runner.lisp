;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The one command that runs the whole suite, and says so when it runs nothing.
;;;;
;;;; Rove can find a system's suites on its own -- (rove:run :cl-wayland-tests) --
;;;; by mapping each fasl back to the source file it came from and asking which
;;;; package was current there.  That mapping only holds when the fasl lives in
;;;; ASDF's user cache: build with a different output translation (a cold-cache
;;;; check, a packager's build) and every suite silently disappears while the run
;;;; still reports success.  A suite that runs zero tests and exits 0 is worse
;;;; than no suite, so the packages are named here, and a missing or empty one is
;;;; a failure.
;;;;
;;;; The list means adding a test file is a two-line change: the .asd component
;;;; and +SUITES+.

(in-package #:cl-user)

(defpackage #:wayland.test.runner
  (:use #:cl)
  (:import-from #:rove/core/suite/package #:suite-tests)
  (:import-from #:rove/core/stats #:*stats* #:stats)
  (:documentation
   "Runs every test suite in cl-wayland-tests and reports one verdict.")
  (:export #:run-all
           #:main
           #:+suites+))

(in-package #:wayland.test.runner)

(defparameter +suites+
  '(wayland.test.wire
    wayland.test.io
    wayland.test.object
    wayland.test.reactor
    wayland.test.schema
    wayland.test.codegen
    wayland.test.input
    wayland.test.client
    wayland.test.server
    wayland.test.scene
    wayland.test.render
    wayland.test.drm
    wayland.test.switcher
    wayland.test.tinywl)
  "Test packages, in dependency order.  Each holds one file's tests.")

(defun suite-result (suite style)
  "Run SUITE under a fresh reporter; return (values passed-p tests failed pending).

A reporter *is* the statistics object Rove records into, and ROVE:WITH-REPORTER
gives each suite a fresh one.  Binding a bare STATS object instead would keep
the counters tidy but silence the reporter, so a failing suite would say how many
tests failed and nothing about which."
  (rove:with-reporter style
    (let ((passed-p (rove:run-suite suite)))
      (values passed-p
              (length (suite-tests suite))
              (length (rove:failed-tests *stats*))
              (length (rove:pending-tests *stats*))))))

(defun run-all (&key (stream *standard-output*) (style :spec))
  "Run every suite in +SUITES+.  Returns true when all ran and all passed."
  (let ((all-passed t)
        (problems '())
        (tests 0)
        (failed 0)
        (pending 0))
    (dolist (name +suites+)
      (let ((suite (rove:find-suite name)))
        (cond
          ((null suite)
           (setf all-passed nil)
           (push (format nil "suite ~A is not defined; did its file load?" name)
                 problems))
          ((zerop (length (suite-tests suite)))
           (setf all-passed nil)
           (push (format nil "suite ~A contains no tests" name) problems))
          (t
           (multiple-value-bind (passed-p suite-tests suite-failed suite-pending)
               (suite-result suite style)
             (unless passed-p
               (setf all-passed nil))
             (incf tests suite-tests)
             (incf failed suite-failed)
             (incf pending suite-pending))))))
    (format stream "~&~D suite~:P, ~D test~:P, ~D failed, ~D skipped~%"
            (length +suites+) tests failed pending)
    (dolist (problem (reverse problems))
      (format stream "  ~A~%" problem))
    (let ((ok (and all-passed (null problems))))
      (format stream "~&~:[FAILED~;PASSED~]~%" ok)
      ok)))

(defun main ()
  "Entry point for scripts: run everything, exit with the verdict.

The compact reporter is right for logs; TEST_VERBOSE=1 asks for every assertion
and its form, which is what you want when reading a failure in a terminal."
  (uiop:quit (if (run-all :style (if (uiop:getenv "TEST_VERBOSE") :spec :dot))
                 0 1)))

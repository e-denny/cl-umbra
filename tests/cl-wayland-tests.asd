;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; Test suite for the cl-wayland-project systems, on Rove.
;;;;
;;;; One package per test file is one Rove suite: DEFTEST registers a test in the
;;;; suite of the package it is read in, and ROVE:RUN on this system finds those
;;;; packages from the system's source files.  So "run the tests" is
;;;; (rove:run :cl-wayland-tests), and "run one file" is (rove:run-suite
;;;; 'wayland.test.wire).
;;;;
;;;; Why the package unlock: Rove depends on DISSECT for rendering failures, and
;;;; dissect 20231021's SBCL backend interns symbols from SB-DI, which SBCL 2.6
;;;; locks.  Unlocking it here -- in the test system, before ROVE is loaded --
;;;; keeps the workaround out of every other system and out of the scripts.
;;;; Nothing we ship depends on Rove or dissect.  Drop this when dissect fixes
;;;; its SBCL backend; a stale unlock of SB-DI is harmless but pointless.

(eval-when (:compile-toplevel :load-toplevel :execute)
  #+sbcl (sb-ext:unlock-package "SB-DI"))

(defsystem "cl-wayland-tests"
  :description "Test suite for the cl-wayland-project systems (Rove)."
  :license "GPL-3.0-or-later"
  :version "0.0.1"
  :depends-on ("rove" "cl-wayland-core" "cl-wayland-protocols" "cl-wayland-client")
  :serial t
  :components ((:file "runner")
               (:module "unit"
                :serial t
                :components ((:file "wire")
                             (:file "io")
                             (:file "reactor")
                             (:file "schema")
                             (:file "codegen")
                             (:file "client"))))
  ;; The perform body is read while this file is loaded, long before the runner
  ;; is on the system, so its symbols are looked up by name.
  :perform (test-op (operation component)
             (declare (ignore operation component))
             (unless (uiop:symbol-call :wayland.test.runner :run-all)
               (error "the test suite did not pass"))))

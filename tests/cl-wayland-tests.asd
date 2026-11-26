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
  #+sbcl (sb-ext:unlock-package "SB-DI")
  ;; dissect 20231021 renders a failing test's locals with SB-DI::DEBUG-VAR-INFO,
  ;; which SBCL 2.6 no longer has: any failure then crashes the reporter, hiding
  ;; the failure itself.  The stand-in returns NIL, so reports lose only the
  ;; :more-context filtering.  Same workaround as the unlock above; delete both
  ;; when dissect catches up with SBCL.
  #+sbcl
  ;; The symbol is interned by this form's own evaluation, not by the reader: the
  ;; .asd is read while SB-DI is still locked, so it must not appear as a symbol
  ;; in the source.
  (let ((package (find-package "SB-DI")))
    (when package
      (multiple-value-bind (symbol status) (find-symbol "DEBUG-VAR-INFO" package)
        (declare (ignore status))
        (let ((symbol (or symbol (intern "DEBUG-VAR-INFO" package))))
          (unless (fboundp symbol)
            (setf (fdefinition symbol)
                  (lambda (variable) (declare (ignore variable)) nil))))))))

(defsystem "cl-wayland-tests"
  :description "Test suite for the cl-wayland-project systems (Rove)."
  :license "GPL-3.0-or-later"
  :version "0.0.1"
  :depends-on ("rove" "cl-wayland-core" "cl-wayland-protocols" "cl-wayland-client"
               "cl-wayland-server" "cl-compositor-framework" "cl-tinywl")
  :serial t
  :components ((:file "runner")
               (:module "unit"
                :serial t
                :components ((:file "wire")
                             (:file "io")
                             (:file "object")
                             (:file "reactor")
                             (:file "schema")
                             (:file "codegen")
                             (:file "input")
                             (:file "client")
                             (:file "server")
                             (:file "scene")
                             (:file "render")
                             (:file "switcher")
                             (:file "tinywl"))))
  ;; The perform body is read while this file is loaded, long before the runner
  ;; is on the system, so its symbols are looked up by name.
  :perform (test-op (operation component)
             (declare (ignore operation component))
             (unless (uiop:symbol-call :wayland.test.runner :run-all)
               (error "the test suite did not pass"))))

(defsystem "cl-wayland-tests/fuzz"
  :description "Decoder fuzzer: random octets through the header decoder,
argument decoders and a real socket pair (docs/testing.md §4)."
  :license "GPL-3.0-or-later"
  :version "0.0.1"
  ;; The protocol system is required so there are real schemas to decode random
  ;; bodies against; it also proves the client's schema path under garbage.
  :depends-on ("cl-wayland-core" "cl-wayland-protocols")
  :serial t
  :components ((:file "fuzz/rng")
               (:file "fuzz/fuzz")))

(defsystem "cl-wayland-tests/fuzz-client"
  :description "Peer fuzzer: random and adversarial clients against a live
display, asserting the server cannot crash, wedge, leak or answer malformed
(docs/testing.md §4)."
  :license "GPL-3.0-or-later"
  :version "0.0.1"
  ;; The server and its schemas, because this fuzzer is the server's first real
  ;; adversary; the shared seeded generator so a seed means the same thing here
  ;; as in the decoder fuzzer.
  :depends-on ("cl-wayland-core" "cl-wayland-protocols" "cl-wayland-server")
  :serial t
  :components ((:file "fuzz/rng")
               (:file "fuzz/client-fuzz")))

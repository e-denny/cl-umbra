;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later

(defsystem "cl-wayland-tests"
  :description "Test suite for the cl-wayland-project systems."
  :license "GPL-3.0-or-later"
  :version "0.0.1"
  :depends-on ("cl-wayland-core")
  :serial t
  :components ((:file "harness")
               (:module "unit"
                :serial t
                :components ((:file "wire")
                             (:file "io"))))
  :perform (test-op (operation component)
             (declare (ignore operation component))
             (unless (zerop (uiop:symbol-call :wayland.test :run-all))
               (error "test suite failed"))))

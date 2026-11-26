;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later

(defsystem "cl-tinywl"
  :description "tinywl, ported: the smallest compositor that proves the framework."
  :license "GPL-3.0-or-later"
  :version "0.0.1"
  :depends-on ("cl-compositor-framework")
  :serial t
  :components ((:file "src/package")
               (:file "src/tinywl")
               (:file "src/main")))

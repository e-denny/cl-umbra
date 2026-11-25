;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later

(defsystem "cl-umbra"
  :description "A daily-driver compositor: layouts, workspaces, rules, config,
and a control surface that is just the running Lisp image."
  :license "GPL-3.0-or-later"
  :version "0.0.1"
  :depends-on ("cl-compositor-framework")
  :serial t
  :components ((:file "src/package")))

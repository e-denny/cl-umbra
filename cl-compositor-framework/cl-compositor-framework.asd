;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later

(defsystem "cl-compositor-framework"
  :description "A Lisp framework that does wlroots' job: backends, renderer,
scene graph, seat and focus policy, and the shell protocol state machines."
  :license "GPL-3.0-or-later"
  :version "0.0.1"
  :depends-on ("cl-wayland-core" "cl-wayland-server")
  :serial t
  :components ((:file "src/package")))

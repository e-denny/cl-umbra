;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later

(defsystem "cl-wayland-server"
  :description "Wayland server: socket, clients, globals and resource lifecycle."
  :license "GPL-3.0-or-later"
  :version "0.0.1"
  :depends-on ("cl-wayland-core")
  :serial t
  :components ((:file "src/package")))

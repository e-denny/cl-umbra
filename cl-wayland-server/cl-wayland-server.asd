;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later

(defsystem "cl-wayland-server"
  :description "Wayland server: socket, clients, globals and resource lifecycle.
Not a libwayland-server binding: the wire format and the object model are ours."
  :license "GPL-3.0-or-later"
  :version "0.0.1"
  ;; The generated WAYLAND package supplies the request and event generic
  ;; functions this system specialises, so the protocol system is a hard
  ;; dependency (docs/protocol-layer.md §4.3).
  :depends-on ("cl-wayland-core" "cl-wayland-protocols")
  :serial t
  :components ((:file "src/package")
               (:file "src/conditions")
               (:file "src/objects")
               (:file "src/socket")
               (:file "src/resource")
               (:file "src/messages")
               (:file "src/client")
               (:file "src/display")
               (:file "src/global")
               (:file "src/shm")
               (:file "src/surface")
               (:file "src/region")
               (:file "src/xdg-shell")
               (:file "src/seat")
               (:file "src/events")
               (:file "src/registry")
               (:file "src/dispatch")
               (:file "src/demo")))

(defsystem "cl-wayland-server/demo"
  :description "wayland-server-demo: a Lisp server that wayland-info can talk to
(the phase-1 demo).  Run from source with
  sbcl ... --eval '(wayland.server.demo:toplevel)'
or build it with (asdf:make :cl-wayland-server/demo)."
  :license "GPL-3.0-or-later"
  :version "0.0.1"
  :depends-on ("cl-wayland-server")
  :build-operation program-op
  :build-pathname "wayland-server-demo"
  :entry-point "wayland.server.demo:toplevel"
  :components ((:file "demo/server-demo")))

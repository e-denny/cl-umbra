;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later

(defsystem "cl-wayland-client"
  :description "Wayland client: display connection, proxies and registry."
  :license "GPL-3.0-or-later"
  :version "0.0.1"
  ;; The generated WAYLAND package is where the request generic functions this
  ;; system specialises come from, so the protocol system is a hard dependency,
  ;; not an optional extra.
  :depends-on ("cl-wayland-core" "cl-wayland-protocols")
  :serial t
  :components ((:file "src/package")
               (:file "src/proxy")
               (:file "src/display")
               (:file "src/registry")))

(defsystem "cl-wayland-client/demo"
  :description "demo-globals: print the globals of the session this process is
in, the phase-0 walking skeleton."
  :license "GPL-3.0-or-later"
  :version "0.0.1"
  :depends-on ("cl-wayland-client")
  :build-operation program-op
  :build-pathname "demo-globals"
  :entry-point "wayland.client.demo:main"
  :components ((:file "demo/demo-globals")))

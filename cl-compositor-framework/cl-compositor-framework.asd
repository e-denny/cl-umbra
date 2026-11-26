;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later

(defsystem "cl-compositor-framework"
  :description "A Lisp framework that does wlroots' job: backends, renderer,
scene graph, seat and focus policy, and the shell protocol state machines."
  :license "GPL-3.0-or-later"
  :version "0.0.1"
  ;; CFFI is for libpixman, the reference renderer (D3); the protocol system for
  ;; the generated interface metadata the surface and shm code uses; nothing here
  ;; touches libwayland, libwlroots, EGL or DRM.
  :depends-on ("cffi" "cl-wayland-core" "cl-wayland-protocols" "cl-wayland-server")
  :serial t
  :components ((:file "src/package")
               (:file "src/render-pixman")
               (:file "src/scene")
               (:file "src/xkb")
               (:file "src/png")
               (:file "src/headless")))

;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later

(in-package #:cl-user)

(defpackage #:tinywl
  (:use #:cl)
  (:local-nicknames (#:srv #:wayland.server)
                    (#:reactor #:wayland.reactor)
                    (#:scene #:cf.scene)
                    (#:grab #:cf.grab)
                    (#:kb #:cf.keybindings)
                    (#:input #:cf.input)
                    (#:nested #:cf.backend.nested)
                    (#:headless #:cf.backend.headless)
                    (#:vt #:cf.backend.vt)
                    (#:seat #:cf.session)
                    (#:ffi #:wayland.ffi))
  (:documentation
   "tinywl, ported: the smallest compositor that proves the framework.

Nothing here reaches below CF's public contracts.  What is left when the framework
has done its job is policy, and policy is what this package is: where a new window
goes, what a pointer press means, what an edge does, which keys belong to the
compositor, and how a session starts and stops.")
  (:export
   ;; the compositor and its policy
   #:tinywl-compositor
   #:make-tinywl
   #:focus-toplevel
   #:desktop-toplevel-at
   #:begin-interactive
   #:edges-at
   #:pointer-reach
   #:install-keybindings
   #:install-vt-bindings
   #:tinywl-vt-seat
   #:close-toplevels
   #:parent-socket-path
   #:launch
   #:stop-clients
   #:*terminal-command*
   #:*clients*
   ;; a session: headless, nested inside another compositor, or on a VT
   #:session
   #:session-mode
   #:session-compositor
   #:session-nested
   #:session-vt-output
   #:session-seat
   #:session-input
   #:start
   #:advance
   #:run
   #:stop
   ;; the command line
   #:main))

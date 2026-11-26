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
                    (#:nested #:cf.backend.nested))
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
   #:install-keybindings
   #:close-toplevels
   #:parent-socket-path
   ;; a session: headless, or nested inside another compositor
   #:session
   #:session-mode
   #:session-compositor
   #:session-nested
   #:start
   #:advance
   #:run
   #:stop
   ;; the command line
   #:main))

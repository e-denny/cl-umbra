;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The demo display: two dummy globals, enough for `wayland-info` to talk to.
;;;;
;;;; The phase-1 gate is "wayland-info exits 0 against our server".  That needs
;;;; globals it can bind and query, not a compositor: wl_compositor (bind and
;;;; release only) and wl_output (the events wayland-info prints).  Nothing here
;;;; draws anything, and nothing here pretends to.

(in-package #:wayland.server)

(defun send-demo-output-events (output)
  "The initial events of a dummy 1024x768 output, in libwayland's order.

wl_output.done is last, and the version gates in SEND-EVENT drop scale, name,
description and done for a v1 resource without this function deciding."
  (wl-output.geometry output
                      0 0                         ; x, y
                      0 0                         ; physical size, unknown
                      0                           ; subpixel: unknown
                      "cl-umbra" "demo output"    ; make, model
                      0)                          ; transform: normal
  (wl-output.mode output
                  1                           ; flags: current
                  1024 768                    ; width, height
                  60000)                      ; refresh, mHz
  (wl-output.scale output 1)
  (wl-output.name output "HEADLESS-1")
  (wl-output.description output "cl-umbra phase-1 demo output")
  (wl-output.done output))

(defun make-demo-display (&key (display-name (uiop:getenv "WAYLAND_DISPLAY"))
                               (runtime-dir (uiop:getenv "XDG_RUNTIME_DIR"))
                               (reactor (make-reactor)))
  "A display offering wl_compositor and wl_output, for the phase-1 gate.

The globals are registered before the socket accepts anything, so every client
sees the same list in the same order."
  (let ((display (make-display :display-name display-name
                               :runtime-dir runtime-dir
                               :reactor reactor)))
    (add-global display
                :interface "wl_compositor"
                :version 1
                :resource-class 'compositor)
    (add-global display
                :interface "wl_output"
                :version 4
                :resource-class 'output
                :bind #'send-demo-output-events)
    display))

;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; Looking up a message by opcode, on either side of an interface.
;;;;
;;;; The schema stores requests and events as lists whose position *is* the
;;;; opcode (docs/protocol-layer.md §4.1), so this is an array reference with a
;;;; range check.  The client has the same two helpers in its own package; the
;;;; two dispatch layers are hand-written on purpose (docs/protocol-layer.md
;;;; §4.3), and each owns the errors it reports.

(in-package #:wayland.server)

(defun request-at-opcode (interface opcode)
  "The wl-message for request OPCODE of INTERFACE, or NIL if there is none."
  (let ((requests (interface-requests interface)))
    (and (< opcode (length requests))
         (nth opcode requests))))

(defun event-at-opcode (interface opcode)
  "The wl-message for event OPCODE of INTERFACE.  A missing one is a bug in us,
not in the client: every event we send is declared in the XML."
  (let ((events (interface-events interface)))
    (or (and (< opcode (length events)) (nth opcode events))
        (error 'internal-error
               :detail (format nil "~A has no event with opcode ~D"
                               (interface-name interface) opcode)))))

(defun handler-function (request)
  "The generic function REQUEST became, if this image has one."
  (let ((symbol (message-symbol request)))
    (and symbol (fboundp symbol) (fdefinition symbol))))

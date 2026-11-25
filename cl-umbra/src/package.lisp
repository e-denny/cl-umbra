;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later

(in-package #:cl-user)

(defpackage #:umbra
  (:use #:cl)
  (:documentation
   "The compositor.  Its exported functions are also its control surface: a REPL
attached to the running image is the interface, so there is no IPC layer
(decision D14, docs/config-and-control.md).  Phase 0 placeholder."))

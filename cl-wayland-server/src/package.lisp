;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later

(in-package #:cl-user)

(defpackage #:wayland.server
  (:use #:cl)
  (:nicknames #:wl.server)
  (:documentation
   "Wayland server: display, globals, resources, clients and their lifecycle.

Phase 0 placeholder: the package exists so the system loads and downstream
systems can depend on it.  Contents arrive in phase 1 (docs/roadmap.md, `Phase 1
-- Server core`)."))

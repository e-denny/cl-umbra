;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later

(in-package #:cl-user)

(defpackage #:wayland.client
  (:use #:cl)
  (:nicknames #:wl.client)
  (:documentation
   "Wayland client: display connection, proxies, registry, event dispatch.

Phase 0 placeholder: the package exists so the system loads and downstream
systems can depend on it.  Contents arrive with the phase-0 client task
(docs/roadmap.md, `cl-wayland-client` minimal)."))

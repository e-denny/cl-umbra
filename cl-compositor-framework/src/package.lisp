;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later

(in-package #:cl-user)

(defpackage #:cf
  (:use #:cl)
  (:nicknames #:cl-compositor-framework)
  (:documentation
   "The compositor framework: everything wlroots provides, in Lisp.

One sub-package per module is added as modules land (CF.BACKEND, CF.RENDER,
CF.SCENE, CF.TYPES, CF.UTIL, CF.SESSION); see docs/framework.md for the module
map and the contracts between them.

Phase 0 placeholder: the package exists so the system loads and downstream
systems can depend on it."))

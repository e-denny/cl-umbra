;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later

(defsystem "cl-wayland-asdf"
  :description "ASDF component type :WAYLAND-PROTOCOL: generates Lisp source
from protocol XML and compiles it, like :CFFI-GROVEL-FILE does for C."
  :license "GPL-3.0-or-later"
  :version "0.0.1"
  ;; No dependencies: this system is loaded by DEFSYSTEM-DEPENDS-ON, before any
  ;; consuming .asd is read.  WAYLAND.CODEGEN is called at perform time, when
  ;; the consuming system's :DEPENDS-ON have been loaded.
  :serial t
  :components ((:file "src/asdf")))

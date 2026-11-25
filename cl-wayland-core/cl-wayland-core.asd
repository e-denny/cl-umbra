;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later

(defsystem "cl-wayland-core"
  :description "Wayland wire format, protocol schema and reactor: a replacement
for libwayland, written from the socket up."
  :license "GPL-3.0-or-later"
  :version "0.0.1"
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "packages")
                             (:file "wire")))))

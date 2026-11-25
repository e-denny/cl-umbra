;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later

(defsystem "cl-wayland-protocols"
  :description "Generated Lisp metadata for the protocol XML this project uses.
Every symbol here is produced from protocols/ at build time; nothing in this
system is written by hand."
  :license "GPL-3.0-or-later"
  :version "0.0.1"
  :defsystem-depends-on ("cl-wayland-asdf")
  :depends-on ("cl-wayland-core")
  :components ((:module "protocols"
                :pathname "../protocols/"
                :components
                ((:module "wayland"
                  :components ((:wayland-protocol "wayland")))
                 (:module "wayland-protocols"
                  :components
                  ((:module "stable"
                    :components
                    ((:module "xdg-shell"
                      :components ((:wayland-protocol "xdg-shell")))))))))))

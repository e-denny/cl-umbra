;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The registry: the two requests every client makes first.
;;;;
;;;; wl_display.get_registry creates one registry object per connection; the
;;;; server then sends one wl_registry.global event per global (plus
;;;; global_remove for hotplugs) and nothing else until the client binds.
;;;;
;;;; wl_registry.bind is the interesting one.  The XML says (name, id); the wire
;;;; says (name, interface, version, id), signature "usun", because the server
;;;; needs the interface name and version to instantiate the right resource
;;;; class (docs/protocol-layer.md §8).  The id is allocated here, before the
;;;; call, because a new_id is always the sender's choice.

(in-package #:wayland.client)

(defclass registry (proxy) ()
  (:documentation
   "The connection's wl_registry.  Subclass it to specialise wl-registry.global
and wl-registry.global-remove as methods instead of hooks."))

(defmethod wl-display.get-registry ((display display))
  "Create the connection's registry object."
  (check-live display)
  (let ((registry (allocate-proxy display "wl_registry" :version 1
                                  :class 'registry)))
    (send-request display (interface-request "wl_display" 1) (proxy-id registry))
    registry))

(defmethod wl-registry.bind ((registry registry) name interface version)
  "Bind global NAME, of INTERFACE, at VERSION; return the new proxy.

VERSION is clamped to what the loaded protocol knows (CLAMP-VERSION), and the
interface must be one this image has a schema for: binding an interface we
cannot decode would only move the failure to the first event."
  (check-live registry)
  (let* ((interface (resolve-interface interface))
         (bound (allocate-proxy (proxy-display registry) interface :version version)))
    (send-request registry (interface-request "wl_registry" 0)
                  name
                  (interface-name (proxy-interface bound))
                  (proxy-version bound)
                  (proxy-id bound))
    bound))

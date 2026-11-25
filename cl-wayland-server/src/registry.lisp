;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The requests phase 1 answers: display, registry, and the destructors of the
;;;; globals the demo offers.
;;;;
;;;; Each is a method on a generated request generic function, specialised on
;;;; this server's resource classes (D15: the new_id is not an argument; the
;;;; method allocates with ALLOCATE-RESOURCE and the dispatch layer has already
;;;; validated the id the client chose).

(in-package #:wayland.server)

;;; ---------------------------------------------------------------------------
;;; wl_display
;;; ---------------------------------------------------------------------------

(defmethod wl-display.get-registry ((display display-resource))
  "Create a registry for this connection and send it every global.

Each call makes a new wl_registry: a client is allowed to ask more than once,
and each registry is an independent object that receives its own copy of the
list (and of later global add/remove events)."
  (let ((client (resource-client display)))
    (let ((registry (allocate-resource client
                                       (resolve-interface "wl_registry")
                                       :version 1
                                       :class 'registry)))
      (dolist (global (display-globals (client-display client)))
        (wl-registry.global registry
                            (global-name global)
                            (global-interface global)
                            (global-version global)))
      registry)))

(defmethod wl-display.sync ((display display-resource))
  "Create a wl_callback that fires when this batch of requests is done.

Not inside the request: SERVICE-CLIENT runs the callbacks after PUMP returns, so
every request that arrived in the same read is processed first.  That is what
makes sync a barrier (docs/protocol-layer.md §5)."
  (let* ((client (resource-client display))
         (callback (allocate-resource client
                                      (resolve-interface "wl_callback")
                                      :version 1
                                      :class 'callback)))
    (setf (client-pending-callbacks client)
          (append (client-pending-callbacks client) (list callback)))
    callback))

;;; ---------------------------------------------------------------------------
;;; wl_registry
;;; ---------------------------------------------------------------------------

(defmethod wl-registry.bind ((registry registry) name interface version)
  "Bind global NAME at VERSION; return the resource.

The four wire arguments are (name, interface, version, id) -- the XML says only
(name, id), but the server needs the interface name and version to instantiate
the right class, which is why the wire is what it is (docs/protocol-layer.md §8).
Everything is validated here, and each failure is the client's fault:

  * no global with that name            -> invalid_object
  * the interface does not match        -> invalid_object
  * a version outside 1..the global's   -> invalid_object
  * an id that is in use or out of range -> caught before this method runs"
  (let* ((client (resource-client registry))
         (display (client-display client))
         (object-id (resource-id registry))
         (global (find-global display name)))
    (unless global
      (protocol-error client object-id +error-invalid-object+
                      "no global with name ~D" name))
    (unless (string= interface (global-interface global))
      (protocol-error client object-id +error-invalid-object+
                      "global ~D is ~A, not ~A"
                      name (global-interface global) interface))
    (unless (<= 1 version (global-version global))
      (protocol-error client object-id +error-invalid-object+
                      "cannot bind ~A at version ~D; this server offers 1..~D"
                      interface version (global-version global)))
    (let ((resource (allocate-resource client
                                       (resolve-interface interface)
                                       :version version
                                       :class (global-resource-class global))))
      (when (global-bind-function global)
        (funcall (global-bind-function global) resource))
      resource)))

;;; ---------------------------------------------------------------------------
;;; Destructors
;;; ---------------------------------------------------------------------------

(defmethod wl-compositor.release ((compositor compositor))
  (destroy-resource compositor))

(defmethod wl-output.release ((output output))
  (destroy-resource output))

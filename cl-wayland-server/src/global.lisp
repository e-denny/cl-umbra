;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; Globals: what this compositor offers, and answering binds.
;;;;
;;;; A global is a name (a small integer the server picks), an interface name, a
;;;; version, and optionally a function that sends the interface's initial
;;;; events once a client binds it (docs/protocol-layer.md §5).
;;;;
;;;; Ordering rule that clients depend on: everything a client is entitled to
;;;; know is queued before the wl_callback.done that answers its next sync.  That
;;;; falls out of the design -- events are appended to the out buffer as they are
;;;; produced, and done is queued when the batch ends -- so nothing here has to
;;;; defer anything.

(in-package #:wayland.server)

(defun find-global (display name)
  "The global registered as NAME, or NIL."
  (find name (display-globals display) :key #'global-name))

(defun check-global (interface version)
  "The schema for INTERFACE, if this image has it and VERSION is speakable.

A global for an interface we cannot decode would fail at the *client's* first
request, which is the worst possible place to discover it."
  (let ((schema (handler-case (resolve-interface interface)
                  (error () nil))))
    (unless schema
      (error 'server-error
             :detail (format nil "cannot offer ~A: this image has no schema for it"
                             interface)))
    (unless (<= 1 version (interface-version schema))
      (error 'server-error
             :detail (format nil "cannot offer ~A at version ~D; the schema knows 1..~D"
                             interface version (interface-version schema))))
    schema))

(defun add-global (display &key interface version
                                (resource-class 'resource) bind data)
  "Register a global and tell every connected registry about it.

Returns the GLOBAL.  Globals added after clients are connected are announced
immediately, in registration order; a client that has not yet synced will see
the announcement before its callback fires."
  (check-global interface version)
  (let ((global (make-instance 'global
                               :name (display-next-global-name display)
                               :interface interface
                               :version version
                               :resource-class resource-class
                               :bind bind
                               :data data)))
    (incf (display-next-global-name display))
    (setf (display-globals display)
          (append (display-globals display) (list global)))
    (dolist (client (display-clients display))
      (dolist (registry (client-registries client))
        (wl-registry.global registry
                            (global-name global)
                            (global-interface global)
                            (global-version global))))
    global))

(defun remove-global (display global)
  "Unregister GLOBAL and tell every connected registry that it is gone."
  (setf (display-globals display) (remove global (display-globals display)))
  (dolist (client (display-clients display))
    (dolist (registry (client-registries client))
      (wl-registry.global-remove registry (global-name global))))
  global)

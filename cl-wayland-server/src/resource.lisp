;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; Resource lifetime.
;;;;
;;;; A resource is born either from a client's new_id (the client chose the id)
;;;; or from the server's own range, and dies exactly once.  The three things
;;;; that must happen together are (docs/protocol-layer.md §3, §8):
;;;;
;;;;   1. the id leaves the client's object table, so a later request on it is
;;;;      invalid_object rather than a use-after-free;
;;;;   2. a client-chosen id goes back into circulation, and the client is told
;;;;      with wl_display.delete_id;
;;;;   3. a server-chosen id does *not* get a delete_id: it was never the
;;;;      client's to reuse.

(in-package #:wayland.server)

;;; ---------------------------------------------------------------------------
;;; Creating
;;; ---------------------------------------------------------------------------

(defun make-resource (client id interface &key (version 1) (class 'resource))
  "Create the resource for ID and install it in CLIENT's table.

INTERFACE is a WL-INTERFACE (the schema), not a string, so that a resource can
never exist whose opcodes are unknown."
  (when (object-table-ref (client-objects client) id)
    (error 'internal-error
           :client client
           :detail (format nil "object id ~D is already in use" id)))
  (let ((resource (make-instance class
                                 :client client
                                 :id id
                                 :interface interface
                                 :version version)))
    (object-table-set (client-objects client) id resource)
    ;; Newest first; TEARDOWN-CLIENT walks this list in order, which is
    ;; therefore reverse creation order (docs/architecture.md §7).
    (push resource (client-resources client))
    resource))

(defun allocate-resource (client interface &key (version 1) (class 'resource))
  "Create the resource for the new_id the request being dispatched named.

This is how a compositor's request method gets the object the wire asked for
(D15): the id came from the client, the dispatch layer stashed it, and the
handler claims it here."
  (let ((id (take-new-id client)))
    (unless id
      (error 'internal-error
             :client client
             :detail "a request with no new_id tried to allocate a resource"))
    (make-resource client id interface :version version :class class)))

;;; ---------------------------------------------------------------------------
;;; The id the current request carries
;;; ---------------------------------------------------------------------------

(defun pending-new-id (client)
  "The next new_id of the request being dispatched, without consuming it."
  (first (client-pending-new-ids client)))

(defun take-new-id (client)
  "Consume the next new_id of the request being dispatched."
  (pop (client-pending-new-ids client)))

;;; ---------------------------------------------------------------------------
;;; Destroying
;;; ---------------------------------------------------------------------------

(defun destroy-resource (resource)
  "Destroy RESOURCE: unlink the id, recycle it, tell the client.  Idempotent."
  (unless (resource-destroyed-p resource)
    (setf (resource-destroyed-p resource) t)
    (let* ((client (resource-client resource))
           (id (resource-id resource)))
      (object-table-remove (client-objects client) id)
      ;; Only a client-chosen id is recyclable, and only a live client needs to
      ;; hear about it: on teardown there is nobody left to reuse it.
      (when (client-id-p id)
        (release-client-id (client-objects client) id)
        (unless (client-closed-p client)
          (let ((display (client-display-resource client)))
            (when (and display (not (resource-destroyed-p display)))
              ;; delete_id after the destructor has been fully processed, and
              ;; before any event that could reuse the id (docs/protocol-layer.md §8).
              (wl-display.delete-id display id)))))))
  t)

;;; ---------------------------------------------------------------------------
;;; Encoding an event argument that names an object
;;; ---------------------------------------------------------------------------

(defun resource-id-of (value)
  "A resource, or a raw id, as the u32 the wire wants (NIL stays null)."
  (etypecase value
    (null nil)
    (resource (resource-id value))
    (integer (if (zerop value) nil value))))

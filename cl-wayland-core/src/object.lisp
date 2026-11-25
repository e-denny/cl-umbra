;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; Object tables and the two id namespaces.
;;;;
;;;; Every Wayland connection, at either end, is a table from object id to
;;;; object, plus an allocator.  The rules are the ones in
;;;; docs/protocol-layer.md §3:
;;;;
;;;;   id 1            wl_display, always, on both ends
;;;;   2..0xFEFFFFFF   the client allocates; the server only records
;;;;   0xFF000000..    the server allocates, for objects it creates without a
;;;;                   client-supplied new_id (wl_data_offer, and later
;;;;                   keyboard/pointer objects)
;;;;
;;;; Allocation is the lowest free id, as in libwayland, so that a trace of our
;;;; server and a trace of theirs look the same (docs/protocol-layer.md §8).
;;;;
;;;; This file is deliberately ignorant of *what* the objects are: wayland.client
;;;; stores proxies here, wayland.server stores resources.  It also does not know
;;;; about destruction: who sends wl_display.delete_id, and when, is the
;;;; dispatch layer's business, because it differs between the two directions.

(in-package #:wayland.object)

;;; ---------------------------------------------------------------------------
;;; The id namespaces
;;; ---------------------------------------------------------------------------

(defconstant +first-client-id+ 2
  "Id 1 is always wl_display, which neither side allocates.")

(defconstant +client-id-max+ #xFEFFFFFF
  "The last id a client may choose.  The server's range starts above it.")

(defconstant +first-server-id+ #xFF000000
  "The first id only a server may choose.")

(defconstant +max-id+ #xFFFFFFFF
  "The wire's id field is 32 bits, so this is the end of both ranges.")

(defun client-id-p (id)
  "True when ID belongs to the client's half of the namespace."
  (and (integerp id) (<= +first-client-id+ id +client-id-max+)))

(defun server-id-p (id)
  (and (integerp id) (<= +first-server-id+ id +max-id+)))

;;; ---------------------------------------------------------------------------
;;; Conditions
;;; ---------------------------------------------------------------------------

(define-condition id-space-exhausted (error)
  ((limit :initarg :limit :reader id-space-exhausted-limit))
  (:report (lambda (condition stream)
             (format stream
                     "no free object id left below ~D; the peer is leaking ids"
                     (id-space-exhausted-limit condition)))))

;;; ---------------------------------------------------------------------------
;;; The table
;;; ---------------------------------------------------------------------------

(defstruct (object-table (:constructor %make-object-table))
  (objects (make-hash-table :test #'eql) :type hash-table)
  (client-next-id +first-client-id+ :type fixnum)
  ;; Released client ids, ascending: the next allocation is the lowest free id,
  ;; so ids look the way they look under libwayland.
  (client-free-ids nil)
  (server-next-id +first-server-id+ :type fixnum)
  (server-free-ids nil))

(defun make-object-table ()
  "An empty table.  One per connection, at either end."
  (%make-object-table))

(defun object-table-ref (table id)
  "The object registered under ID, or NIL.

NIL is unambiguous here: id 0 is the wire's null object and is never a key."
  (gethash id (object-table-objects table)))

(defun object-table-set (table id object)
  "Register OBJECT under ID.  An id already in use is a bug in the caller: the
dispatch layer validates new ids before it gets here."
  (let ((objects (object-table-objects table)))
    (when (gethash id objects)
      (error "object id ~D is already in use in this table" id))
    (setf (gethash id objects) object)))

(defun object-table-remove (table id)
  "Forget ID and return what was there, or NIL."
  (let ((objects (object-table-objects table)))
    (multiple-value-bind (object present-p) (gethash id objects)
      (when present-p
        (remhash id objects))
      object)))

(defun object-table-count (table)
  (hash-table-count (object-table-objects table)))

(defun object-table-ids (table)
  "Every id in the table, ascending.  For diagnostics and tests, never for
dispatch."
  (sort (loop for id being the hash-keys of (object-table-objects table)
              collect id)
        #'<))

;;; ---------------------------------------------------------------------------
;;; The client half
;;; ---------------------------------------------------------------------------

(defun allocate-client-id (table)
  "The lowest free client id: a released one if there is one, else the counter."
  (if (object-table-client-free-ids table)
      (pop (object-table-client-free-ids table))
      (let ((id (object-table-client-next-id table)))
        (when (> id +client-id-max+)
          (error 'id-space-exhausted :limit (1+ +client-id-max+)))
        (setf (object-table-client-next-id table) (1+ id))
        id)))

(defun release-client-id (table id)
  "Make ID available again, keeping the free list ascending.

Only an id inside the client range is recyclable; a server-chosen id is not the
client's to reuse, and the range check is what keeps the two namespaces from
colliding even if a caller asks."
  (when (client-id-p id)
    (let ((free (object-table-client-free-ids table)))
      (unless (member id free)
        (setf (object-table-client-free-ids table)
              (merge 'list (list id) free #'<)))))
  id)

;;; ---------------------------------------------------------------------------
;;; The server half
;;; ---------------------------------------------------------------------------

(defun allocate-server-id (table)
  "The lowest free server id.  Used when the server creates an object the client
did not name, so no wl_display.delete_id follows its destruction."
  (if (object-table-server-free-ids table)
      (pop (object-table-server-free-ids table))
      (let ((id (object-table-server-next-id table)))
        (when (> id +max-id+)
          (error 'id-space-exhausted :limit (1+ +max-id+)))
        (setf (object-table-server-next-id table) (1+ id))
        id)))

(defun release-server-id (table id)
  (when (server-id-p id)
    (let ((free (object-table-server-free-ids table)))
      (unless (member id free)
        (setf (object-table-server-free-ids table)
              (merge 'list (list id) free #'<)))))
  id)

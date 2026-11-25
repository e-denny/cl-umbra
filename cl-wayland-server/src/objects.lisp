;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The server's classes, in one place so that the files after this one can be
;;;; read in any order without chasing accessor definitions.
;;;;
;;;; Two kinds of object, as in docs/architecture.md §3:
;;;;
;;;;   RESOURCE      a protocol object the client knows by id: wl_display,
;;;;                 wl_registry, wl_callback, and everything phase 2 adds.  A
;;;;                 framework or compositor subclasses it and specialises the
;;;;                 generated request generic functions on the subclass.
;;;;   DISPLAY       this process's server: the socket, the clients on it and
;;;;                 the globals it offers.  Not a resource, and not per client.
;;;;
;;;; A CLIENT is one connection: socket, credentials, an object table and the
;;;; two buffers.  Every id the client learns about lives in its object table
;;;; and nowhere else, so teardown is one table walk and one list of resources
;;;; in creation order.

(in-package #:wayland.server)

;;; ---------------------------------------------------------------------------
;;; Resources
;;; ---------------------------------------------------------------------------

(defclass resource ()
  ((client :initarg :client :reader resource-client)
   (id :initarg :id :reader resource-id)
   (interface :initarg :interface :reader resource-interface)
   (version :initarg :version :initform 1 :reader resource-version)
   ;; Destroyed resources stay allocated until the next GC: the id is gone from
   ;; the client's table immediately, but a handler still running may hold this
   ;; object, and checking the flag beats dereferencing a tombstone.
   (destroyed-p :initform nil :accessor resource-destroyed-p))
  (:documentation
   "A protocol object, identified by (client, id).

Subclass it to give an interface behaviour; specialise the generated request
generic functions on the subclass:

  (defmethod wl-surface.attach ((surface my-surface) buffer x y) ...)

The web of ids, versions and lifetimes is this class's business; what the
interface *means* is the subclass's."))

;;; ---------------------------------------------------------------------------
;;; Clients
;;; ---------------------------------------------------------------------------

(defclass client ()
  ((id :initarg :id :reader client-id)
   (display :initarg :display :reader client-display)
   (fd :initarg :fd :reader client-fd)
   ;; SO_PEERCRED, kept for the log line and for policy.  The kernel only tells
   ;; us once, at accept time (docs/protocol-layer.md §5).
   (pid :initarg :pid :reader client-pid)
   (uid :initarg :uid :reader client-uid)
   (gid :initarg :gid :reader client-gid)
   (input :initform (make-input-buffer) :reader client-input)
   (output :initform (make-message-buffer :capacity 4096) :reader client-output)
   (objects :initform (make-object-table) :reader client-objects)
   ;; Resources in creation order, so teardown destroys them in reverse.  Ids
   ;; are not creation order: a client id can be reused while a server id is
   ;; still in use.
   (resources :initform nil :accessor client-resources)
   (display-resource :initform nil :accessor client-display-resource)
   (source :initform nil :accessor client-source)
   ;; The new_id a request carries is the sender's choice, so the dispatch layer
   ;; stashes it here and the handler claims it with TAKE-NEW-ID (D15).
   (pending-new-ids :initform nil :accessor client-pending-new-ids)
   ;; wl_display.sync callbacks that must fire when this batch of requests is
   ;; done, in the order the syncs arrived.
   (pending-callbacks :initform nil :accessor client-pending-callbacks)
   (closed-p :initform nil :accessor client-closed-p))
  (:documentation
   "One connection: a socket, its peer's credentials, an object table and the
two message buffers.

Everything here dies together in TEARDOWN-CLIENT, which is the only function
allowed to free per-client state (docs/architecture.md §7)."))

;;; ---------------------------------------------------------------------------
;;; The display
;;; ---------------------------------------------------------------------------

(defclass display ()
  ((reactor :initarg :reactor :reader display-reactor)
   (name :initarg :name :reader display-name)
   (socket-path :initarg :socket-path :reader display-socket-path)
   (socket-fd :initarg :socket-fd :reader display-socket-fd)
   (lock-fd :initarg :lock-fd :reader display-lock-fd)
   (source :initform nil :accessor display-source)
   ;; Oldest first, so dispatch order is fair and teardown order is defined.
   (clients :initform nil :accessor display-clients)
   ;; Registration order: wl_registry.global events go out in it.
   (globals :initform nil :accessor display-globals)
   (next-global-name :initform 1 :accessor display-next-global-name)
   (next-client-id :initform 1 :accessor display-next-client-id)
   (serial :initform 0 :accessor display-serial)
   ;; How many connections one readable event may accept.  A connect storm must
   ;; not starve the clients that are already connected.
   (accept-budget :initarg :accept-budget :initform 16 :reader display-accept-budget)
   (closed-p :initform nil :accessor display-closed-p))
  (:documentation
   "The server: listening socket, clients, globals and the reactor they run on.

MAKE-DISPLAY creates the socket and starts accepting; CLOSE-DISPLAY is the one
teardown path, and it is idempotent."))

;;; ---------------------------------------------------------------------------
;;; Globals
;;; ---------------------------------------------------------------------------

(defclass global ()
  ((name :initarg :name :reader global-name)
   ;; The wire name, as a string: it goes on the wire verbatim and is matched
   ;; against what the client asks to bind (docs/protocol-layer.md §8).
   (interface :initarg :interface :reader global-interface)
   (version :initarg :version :reader global-version)
   (resource-class :initarg :resource-class :initform 'resource
                   :reader global-resource-class)
   (bind-function :initarg :bind :initform nil :reader global-bind-function)
   (data :initarg :data :initform nil :reader global-data))
  (:documentation
   "Something the compositor offers: a name, an interface and a version.

BIND-FUNCTION, when present, is called with the newly created resource after the
global is bound, and is where a global sends its initial events (wl_output's
geometry, wl_seat's capabilities)."))

;;; ---------------------------------------------------------------------------
;;; The protocol objects this phase speaks
;;;;
;;;; Plain subclasses: phase 1 has no state beyond what RESOURCE carries.  They
;;;; exist as classes so that the dispatch layer has something to specialise on
;;;; and so that phase 2 can grow slots here instead of changing the transport.
;;; ---------------------------------------------------------------------------

(defclass display-resource (resource)
  ()
  (:documentation "wl_display: always id 1, one per connection."))

(defclass registry (resource)
  ()
  (:documentation "wl_registry: one per wl_display.get_registry, may be several."))

(defclass callback (resource)
  ()
  (:documentation "wl_callback: created by wl_display.sync, fires once, then dies."))

(defclass compositor (resource)
  ()
  (:documentation "wl_compositor: bind, release, and (phase 2) create_surface."))

(defclass output (resource)
  ()
  (:documentation "wl_output: an events-only global; the demo sends geometry and
mode on bind so that wayland-info has something true to print."))

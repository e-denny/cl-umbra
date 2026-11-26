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
   (destroyed-p :initform nil :accessor resource-destroyed-p)
   ;; Called by DESTROY-RESOURCE after the id is gone: a pool unmaps and closes,
   ;; a buffer drops its reference.  Protocol state that owns foreign memory has
   ;; to be released at a defined moment, and resource destruction is that moment.
   (destroy-function :initarg :destroy-function :initform nil
                     :accessor resource-destroy-function))
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
  ((surface-class :initarg :surface-class :initform 'surface
                  :accessor compositor-surface-class))
  (:documentation "wl_compositor: bind, create_surface, and the surface class to
instantiate.

The surface class is a slot, not a constant: a framework subclasses SURFACE and
configures the global with it (D7 -- configured resource classes, no vtables)."))

(defclass output (resource)
  ()
  (:documentation "wl_output: an events-only global; the demo sends geometry and
mode on bind so that wayland-info has something true to print."))

;;; ---------------------------------------------------------------------------
;;; Surfaces
;;; ---------------------------------------------------------------------------

(defclass surface (resource)
  ((pending-attach-p :initform nil :accessor surface-pending-attach-p)
   (pending-buffer :initform nil :accessor surface-pending-buffer)
   (pending-x :initform 0 :accessor surface-pending-x)
   (pending-y :initform 0 :accessor surface-pending-y)
   (pending-damage :initform nil :accessor surface-pending-damage)
   (pending-frame-callbacks :initform nil :accessor surface-pending-frame-callbacks)
   (current-buffer :initform nil :accessor surface-current-buffer)
   (current-x :initform 0 :accessor surface-current-x)
   (current-y :initform 0 :accessor surface-current-y)
   ;; Callbacks requested by commits that have not been presented yet.
   (committed-callbacks :initform nil :accessor surface-committed-callbacks)
   (opaque-region :initform nil :accessor surface-opaque-region)
   (input-region :initform nil :accessor surface-input-region)
   (mapped-p :initform nil :accessor surface-mapped-p)
   (committed-p :initform nil :accessor surface-committed-p)
   ;; The wl_compositor resource that created this surface.  A framework
   ;; subclasses the compositor and puts its own state behind this.
   (owner :initform nil :accessor surface-owner))
  (:documentation
   "wl_surface: the pending/current double buffer of everything a client draws.

Phase 2a implements the part a shm client needs -- attach, damage, frame, commit,
destroy -- and stores the opaque/input regions without acting on them: with no
input and an opaque-by-construction target, ignoring them is correct, not lazy.
Scale, transform and buffer-scale are later slices, and a version-1 binding means
a client never sends them."))

;;; ---------------------------------------------------------------------------
;;; Shared memory
;;; ---------------------------------------------------------------------------

(defclass shm (resource)
  ()
  (:documentation "wl_shm: the global.  Its only state is the format list, which
is a constant; every buffer lives in a wl_shm_pool."))

(defclass shm-pool (resource)
  ((fd :initarg :fd :initform -1 :accessor shm-pool-fd)
   (size :initarg :size :initform 0 :type integer :accessor shm-pool-size)
   (mapping :initform nil :accessor shm-pool-mapping)
   (mapping-length :initform 0 :type integer :accessor shm-pool-mapping-length)
   ;; Live buffers, so that destroying the pool can finish them first.
   (buffers :initform nil :accessor shm-pool-buffers))
  (:documentation "wl_shm_pool: one client file, mapped read-only.

The client keeps writing into the mapping; we only read it at render time.  The
fd is kept for the pool's lifetime (a future resize needs it) and closed when the
pool dies, which is the one place that ownership ends."))

(defclass shm-buffer (resource)
  ((pool :initarg :pool :accessor shm-buffer-pool)
   (offset :initarg :offset :accessor shm-buffer-offset)
   (width :initarg :width :accessor shm-buffer-width)
   (height :initarg :height :accessor shm-buffer-height)
   (stride :initarg :stride :accessor shm-buffer-stride)
   (format :initarg :format :accessor shm-buffer-format)
   ;; A buffer the compositor is drawing from must not be released twice, and a
   ;; buffer still attached to a surface must not be destroyed behind our back.
   (in-use-p :initform nil :accessor shm-buffer-in-use-p)
   (released-p :initform t :accessor shm-buffer-released-p))
  (:documentation "wl_buffer backed by a subrange of a pool.

The pool keeps the buffer alive: destroying the pool destroys its buffers, so a
renderer can never be handed a pointer into an unmapped file."))

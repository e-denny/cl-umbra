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
   ;; The serials this display issued recently, newest first, bounded: the whole
   ;; point of a serial is that a client can echo one back, so "did we issue it"
   ;; has to be answerable, and "how long ago" has to be answerable too (D33).
   (recent-serials :initform nil :accessor display-recent-serials)
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
   ;; Committed region state: a list of (x y width height) or NIL for "no region"
   ;; -- which means "infinitely large" for opaque (nothing is opaque) and that
   ;; the whole surface takes input.  The INPUT region has a third value, :EMPTY,
   ;; for a wl_region with no rectangles (none of the surface takes input).  Both
   ;; pending slots hold the same snapshot, taken when SET_*_REGION is handled:
   ;; a client may destroy or mutate a wl_region right after sending that
   ;; request, and weston's clients do (docs/memory-and-rendering.md §3).
   (opaque-region :initform nil :accessor surface-opaque-region)
   (input-region :initform nil :accessor surface-input-region)
   (pending-opaque-region :initform nil :accessor surface-pending-opaque-region)
   (pending-opaque-region-p :initform nil :accessor surface-pending-opaque-region-p)
   (pending-input-region :initform nil :accessor surface-pending-input-region)
   (pending-input-region-p :initform nil :accessor surface-pending-input-region-p)
   (mapped-p :initform nil :accessor surface-mapped-p)
   (committed-p :initform nil :accessor surface-committed-p)
   ;; wl_surface.set_buffer_transform (since 2) and set_buffer_scale (since 3).
   ;; Validated and stored here; read by the compositor's renderer at frame time,
   ;; which turns the buffer and divides its scale out (D49).
   (buffer-transform :initform 0 :accessor surface-buffer-transform)
   (buffer-scale :initform 1 :accessor surface-buffer-scale)
   ;; The wl_compositor resource that created this surface.  A framework
   ;; subclasses the compositor and puts its own state behind this.
   (owner :initform nil :accessor surface-owner)
   ;; The shell object that gave this surface a role (an XDG-SURFACE today), or
   ;; NIL for a bare surface with no role at all.  A wl_surface has at most one,
   ;; and the shell object -- not this slot -- is where the role's state lives.
   (shell-surface :initform nil :accessor surface-shell-surface))
  (:documentation
   "wl_surface: the pending/current double buffer of everything a client draws.

Phase 2a implements the part a shm client needs -- attach, damage, frame, commit,
destroy -- and stores the opaque/input regions without acting on them: with no
input and an opaque-by-construction target, ignoring them is correct, not lazy.
Scale, transform and buffer-scale are later slices, and a version-1 binding means
a client never sends them.

SHELL-SURFACE is the one hook a role needs: when set, the commit path calls the
role's hooks (see SURFACE.LISP), and the role object owns the protocol state
machine.  A bare surface -- everything phase 2a's clients create -- has none, and
none of the role checks run."))

(defclass region (resource)
  ((rects :initform nil :accessor region-rects))
  (:documentation
   "wl_region: a set of rectangles, as a list of (x y width height).

A region is a set, not a rectangle: ADD is union, SUBTRACT is difference, and the
representation may contain overlapping or adjacent rectangles.  That is legal --
the protocol only defines the area -- but it means consumers must think in terms
of the set, not of one rectangle, and REGION-SUBTRACT produces up to four pieces
per existing rectangle rather than trying to be minimal."))

;;; ---------------------------------------------------------------------------
;;; xdg-shell, version 1
;;;
;;; Three objects, three jobs:
;;;
;;;   XDG-WM-BASE    the global; makes xdg_surfaces and remembers them so that
;;;                  destroying it early can be called what it is (defunct).
;;;   XDG-SURFACE    the configure/ack handshake shared by every role: serials
;;;                  sent, serials acked, whether a buffer was ever legal yet.
;;;   XDG-TOPLEVEL   the window: title, app id, size hints, requested states, and
;;;                  the configure that tells the client what to draw.
;;;   XDG-POPUP      the short-lived child: a copied positioner rule, a parent, the
;;;                  geometry the compositor placed it at, and whether it took an
;;;                  explicit grab.
;;;   XDG-POSITIONER  a rule object, not a surface: size, anchor rectangle, anchor,
;;;                  gravity, constraint adjustment and offset.  A popup takes a
;;;                  *copy* of it, which is why one positioner can place many popups
;;;                  and can be destroyed the moment get_popup has been answered.
;;;
;;; The role is a pointer (XDG-SURFACE-ROLE -> toplevel or popup), not a class
;;; change: the wl_surface is the same object before and after, and
;;; docs/architecture.md §4's CHANGE-CLASS idea only pays off once roles share a
;;; class hierarchy worth changing into.
;;; ---------------------------------------------------------------------------

(defclass xdg-wm-base (resource)
  ((shell-surfaces :initform nil :accessor xdg-wm-base-shell-surfaces)
   ;; Serials of pings sent and not yet ponged, newest first.
   (pending-pings :initform nil :accessor xdg-wm-base-pending-pings)
   (ping-count :initform 0 :accessor xdg-wm-base-ping-count)
   (pong-count :initform 0 :accessor xdg-wm-base-pong-count))
  (:documentation
   "xdg_wm_base: the global a client binds to make windows.

Its only state is bookkeeping the protocol asks for: the live xdg_surfaces (so
that destroying it early is reported as defunct_surfaces) and the pings it is
waiting on (so that a pong can be matched to a ping)."))

(defclass xdg-surface (resource)
  ((surface :initarg :surface :initform nil :accessor xdg-surface-surface)
   (wm-base :initarg :wm-base :initform nil :accessor xdg-surface-wm-base)
   ;; :TOPLEVEL once a role object exists; the role object itself in ROLE.
   (role :initform nil :accessor xdg-surface-role)
   (role-name :initform nil :accessor xdg-surface-role-name)
   ;; The handshake.  CONFIGURED-P: a configure has been sent.  ACKNOWLEDGED-P:
   ;; one has been acked, which is the first moment a buffer is legal.
   (configured-p :initform nil :accessor xdg-surface-configured-p)
   (acknowledged-p :initform nil :accessor xdg-surface-acknowledged-p)
   (configure-serial :initform nil :accessor xdg-surface-configure-serial)
   ;; Serials sent and not yet consumed by ACK-CONFIGURE, newest first.
   (pending-serials :initform nil :accessor xdg-surface-pending-serials)
   (last-acked-serial :initform nil :accessor xdg-surface-last-acked-serial)
   (ack-count :initform 0 :accessor xdg-surface-ack-count)
   (window-geometry :initform nil :accessor xdg-surface-window-geometry)
   (mapped-p :initform nil :accessor xdg-surface-mapped-p)
   ;; NIL once the wl_surface it was created for is gone: the role outliving its
   ;; surface makes every configure a no-op rather than a write to a dead id.
   (live-p :initform t :accessor xdg-surface-live-p))
  (:documentation
   "xdg_surface: the configure/ack_configure handshake, independent of the role.

A client's first commit (no buffer) is answered with a configure; it must ack
that serial before attaching a buffer.  PENDING-SERIALS is what makes a stale or
invented ack a protocol error instead of a shrug."))

(defclass xdg-toplevel (resource)
  ((shell-surface :initarg :shell-surface :initform nil
                  :accessor xdg-toplevel-shell-surface)
   (title :initform nil :accessor xdg-toplevel-title)
   (app-id :initform nil :accessor xdg-toplevel-app-id)
   (parent :initform nil :accessor xdg-toplevel-parent)
   (min-width :initform 0 :accessor xdg-toplevel-min-width)
   (min-height :initform 0 :accessor xdg-toplevel-min-height)
   (max-width :initform 0 :accessor xdg-toplevel-max-width)
   (max-height :initform 0 :accessor xdg-toplevel-max-height)
   ;; What the client asked for.  Phase 3 has no seat and no output policy, so
   ;; these are recorded and ignored; the configure states are computed by the
   ;; compositor, never echoed back from here.
   (maximized-p :initform nil :accessor xdg-toplevel-maximized-p)
   (fullscreen-p :initform nil :accessor xdg-toplevel-fullscreen-p)
   (minimized-p :initform nil :accessor xdg-toplevel-minimized-p)
   ;; The last configure, for tests and for the REPL (D14).
   (configure-count :initform 0 :accessor xdg-toplevel-configure-count)
   (configure-width :initform 0 :accessor xdg-toplevel-configure-width)
   (configure-height :initform 0 :accessor xdg-toplevel-configure-height)
   (configure-states :initform nil :accessor xdg-toplevel-configure-states)
   (mapped-p :initform nil :accessor xdg-toplevel-mapped-p)
   (closed-p :initform nil :accessor xdg-toplevel-closed-p)
   ;; The live popups of this toplevel, oldest first: creation order *is* the
   ;; stacking order ("a newly created xdg_popup will be stacked on top of all
   ;; previously created xdg_popup surfaces associated with the same xdg_toplevel"),
   ;; and it is what makes "not the topmost popup" answerable.
   (popups :initform nil :accessor xdg-toplevel-popups))
  (:documentation
   "xdg_toplevel: a window.

TITLE, APP-ID and the size hints are what a taskbar or a rule engine reads; the
configure event is what the client reads.  Nothing here decides layout: with a
headless output and no scene graph, a mapped toplevel is drawn where its buffer
offset puts it, and that is a documented limit, not an oversight."))

(defclass xdg-positioner (resource)
  ((size :initform nil :accessor xdg-positioner-size)
   (anchor-rect :initform nil :accessor xdg-positioner-anchor-rect)
   (anchor :initform 0 :accessor xdg-positioner-anchor)
   (gravity :initform 0 :accessor xdg-positioner-gravity)
   (constraint-adjustment :initform 0 :accessor xdg-positioner-constraint-adjustment)
   (offset :initform '(0 0) :accessor xdg-positioner-offset))
  (:documentation
   "xdg_positioner: the rules for placing one child surface, and nothing else.

It is not a surface and it draws nothing.  SIZE is (width height) or NIL until
set_size is called, ANCHOR-RECT is (x y width height) or NIL until set_anchor_rect
is called, and those two NILs are what 'incomplete' means: a popup may not be
created from a positioner that has neither.  A popup copies the rules at get_popup,
so changing or destroying the positioner afterwards changes nothing."))

(defclass xdg-popup (resource)
  ((shell-surface :initarg :shell-surface :initform nil
                  :accessor xdg-popup-shell-surface)
   ;; The parent xdg_surface, or NIL for the "some other protocol will say" case
   ;; the v1 XML allows and this compositor cannot honour (no layer-shell yet).
   (parent :initform nil :accessor xdg-popup-parent)
   ;; The positioner rule as it was when get_popup was called.
   (rule :initform nil :accessor xdg-popup-rule)
   ;; Where the compositor placed it, relative to the parent's window geometry:
   ;; (x y width height), from the xdg_popup.configure we sent.  Also the answer to
   ;; "where is the node" for the compositor that drew it.
   (geometry :initform nil :accessor xdg-popup-geometry)
   (configure-count :initform 0 :accessor xdg-popup-configure-count)
   (mapped-p :initform nil :accessor xdg-popup-mapped-p)
   ;; An explicit grab: the popup owns the pointer until it is dismissed.
   (grabbed-p :initform nil :accessor xdg-popup-grabbed-p)
   ;; Dismissed by the compositor (or its client): popup_done was sent and the
   ;; surface is unmapped, but the object may still be alive until the client
   ;; destroys it.
   (dismissed-p :initform nil :accessor xdg-popup-dismissed-p))
  (:documentation
   "xdg_popup: a menu, a tooltip, a dropdown.

Its placement is decided once, from a copy of an xdg_positioner's rules, at the
initial configure; the position is relative to the parent's *window geometry*, which
is why the arithmetic lives with the protocol (POSITIONER-PLACE) and the constraint
area comes from the compositor (POPUP-CONSTRAINT-BOX), expressed in the same space.

DISMISSED-P is not the same as destroyed: the compositor takes a popup off the
screen and tells the client (xdg_popup.popup_done), and the client destroys the
object afterwards, in its own time."))

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

;;; ---------------------------------------------------------------------------
;;; Seats and input, wl_seat version 4
;;;
;;; The seat is the one object here that is *not* a resource: it is a property of
;;; the compositor (a group of devices, with focus), while every client that
;;; binds the global gets its own wl_seat resource beneath it.  Two kinds of
;;; object, and confusing them is how a compositor ends up with per-client focus:
;;;
;;;   SEAT           one per compositor: capabilities, keymap, focus, pointer
;;;                  position, pressed keys, modifier state.
;;;   SEAT-RESOURCE  one per client bind (wl_seat).  It exists so the client can
;;;                  create POINTER, KEYBOARD and TOUCH objects, which are the
;;;                  ones events actually travel on.
;;;
;;; Focus lives on the seat, so "who gets this key" has exactly one answer.
;;; ---------------------------------------------------------------------------

(defclass seat ()
  ((name :initarg :name :initform "seat0" :accessor seat-name)
   (display :initarg :display :reader seat-display)
   ;; Bitmask of WL-SEAT-CAPABILITY-*: what this seat can do *now*.
   (capabilities :initarg :capabilities :initform 0 :accessor seat-capabilities)
   ;; The XKB keymap text every keyboard is given, and the repeat settings that
   ;; follow it.  NIL means "no keymap yet", which is a valid state while a
   ;; backend is still starting; a keyboard created then gets none.
   (keymap :initform nil :accessor seat-keymap)
   (repeat-rate :initform 25 :accessor seat-repeat-rate)
   (repeat-delay :initform 600 :accessor seat-repeat-delay)
   (bindings :initform nil :accessor seat-bindings)
   ;; Pointer buttons physically down, so a grab can end on the button that
   ;; started it instead of assuming the left one (D33).
   (pressed-buttons :initform nil :accessor seat-pressed-buttons)
   ;; The surface that has keyboard focus, and the one under the pointer.
   (keyboard-focus :initform nil :accessor seat-keyboard-focus)
   (pointer-focus :initform nil :accessor seat-pointer-focus)
   (pointer-x :initform 0 :accessor seat-pointer-x)
   (pointer-y :initform 0 :accessor seat-pointer-y)
   ;; Keycodes physically down, so a focus change can tell the new client what it
   ;; is not seeing the press of (wl_keyboard.enter carries the array).
   (pressed-keys :initform nil :accessor seat-pressed-keys)
   ;; Modifier state as the compositor computed it, echoed in
   ;; wl_keyboard.modifiers after every key event.
   (mods-depressed :initform 0 :accessor seat-mods-depressed)
   (mods-latched :initform 0 :accessor seat-mods-latched)
   (mods-locked :initform 0 :accessor seat-mods-locked)
   (group :initform 0 :accessor seat-group))
  (:documentation
   "A seat: capabilities, one keymap, focus, and the modifier state.

It is deliberately not a resource.  Resources are per client and die with it;
focus and modifier state outlive any one client, and two clients binding the same
global must see the same seat."))

(defclass seat-resource (resource)
  ((seat :initarg :seat :initform nil :accessor seat-resource-seat)
   (pointers :initform nil :accessor seat-resource-pointers)
   (keyboards :initform nil :accessor seat-resource-keyboards)
   (touches :initform nil :accessor seat-resource-touches))
  (:documentation
   "wl_seat as one client sees it; the factory for its pointer/keyboard/touch.

Lists, not single slots: the protocol allows get_pointer twice, and a client that
does it gets two independently identified objects."))

(defclass pointer (resource)
  ((seat :initarg :seat :initform nil :accessor pointer-seat)
   (surface :initform nil :accessor pointer-surface)
   ;; set_cursor's request: the image and its hotspot.  Accepted and recorded;
   ;; there is no software cursor to draw yet, so nothing reads it.
   (cursor-surface :initform nil :accessor pointer-cursor-surface)
   (cursor-hotspot-x :initform 0 :accessor pointer-cursor-hotspot-x)
   (cursor-hotspot-y :initform 0 :accessor pointer-cursor-hotspot-y)
   ;; The serial of the last set_cursor.  A compositor needs it for cursor
   ;; animation; a gate needs it as proof that the client received the enter that
   ;; invited the request, which is otherwise invisible from our side.
   (cursor-serial :initform nil :accessor pointer-cursor-serial))
  (:documentation "wl_pointer: enter/leave/motion/button/axis for one client."))

(defclass keyboard (resource)
  ((seat :initarg :seat :initform nil :accessor keyboard-seat)
   (surface :initform nil :accessor keyboard-surface))
  (:documentation "wl_keyboard: keymap, repeat_info, enter/leave, key, modifiers."))

(defclass touch (resource)
  ((seat :initarg :seat :initform nil :accessor touch-seat)
   (surface :initform nil :accessor touch-surface))
  (:documentation
   "wl_touch: created so a capability-less seat never answers `implementation'.

No compositor capability advertises touch yet and no backend injects it, so the
object exists, receives nothing, and is released normally."))

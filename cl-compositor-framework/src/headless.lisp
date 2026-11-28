;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The headless backend: an output that needs no display, no privileges and no
;;;; hardware (docs/memory-and-rendering.md §8.1).
;;;;
;;;; It owns a target, a list of mapped surfaces in commit order, and a frame
;;;; clock.  Phase 2a's clock is an idle callback: a commit marks the compositor
;;;; dirty and a render happens once at the end of that reactor cycle, which is
;;;; "presented" for the purposes of frame callbacks.  A real output clock (timer
;;;; or vblank) replaces the idle without changing the renderer or the surfaces.

(in-package #:cf.backend.headless)

;;; ---------------------------------------------------------------------------
;;; A compositor, not just a backend
;;; ---------------------------------------------------------------------------
;;
;; A headless *backend* in wlroots only provides the output; something has to own
;; the display, the globals and the frame loop, and in phase 2a that something is
;; this object.  It is deliberately small: the modules it would grow into
;; (cf.types.*, cf.scene, cf.seat) arrive with the features that need them.

(defclass cf-surface (srv:surface)
  ((entered-p :initform nil :accessor surface-entered-p)
   ;; The scene node this surface is drawn and hit-tested through, once it maps.
   ;; NIL before the first mapped commit and after the surface is forgotten.
   (scene-node :initform nil :accessor surface-scene-node)
   ;; Did a client ever name this surface as its pointer's image?  Then it is a
   ;; cursor image for good: the protocol has no way to give the surface another
   ;; role, and drawing it would put a cursor at the output's origin (D40).
   (pointer-image-p :initform nil :accessor surface-pointer-image-p)
   ;; The damage this surface has reported since a frame last painted it, in
   ;; surface-local coordinates.  Accumulated at every commit and cleared by the
   ;; frame that drew those pixels: it is the *content* half of a frame's damage,
   ;; the geometry half being the difference between two draw lists (D48).
   (damage-since-frame :initform nil :accessor surface-content-damage))
  (:documentation "A server surface with the framework's own state on top (D7)."))

(defmethod srv:surface-damage-since-frame ((surface cf-surface))
  (surface-content-damage surface))

(defmethod (setf srv:surface-damage-since-frame) (damage (surface cf-surface))
  (setf (surface-content-damage surface) damage))

(defclass cf-compositor (srv:compositor)
  ((headless :initarg :headless :initform nil :accessor cf-compositor-headless))
  (:documentation
   "The per-client wl_compositor, pointing back at the compositor.

The surface class is set at bind time, not by re-specifying the inherited slot:
a DEFCLASS in this package would name a *new* symbol SURFACE-CLASS in
CF.BACKEND.HEADLESS, and CLOS identifies slots by symbol, not by name -- the
symptom is an accessor that cheerfully returns the parent's value while
SLOT-VALUE shows a different one."))

(defclass headless-compositor ()
  ((display :initarg :display :reader compositor-display)
   (width :initarg :width :accessor compositor-width)
   (height :initarg :height :accessor compositor-height)
   ;; Device pixels per layout coordinate (D49).  The output, the scene and every
   ;; policy stay in layout coordinates; only the target and a client's buffer
   ;; scale care, and they both read this one number.
   (scale :initarg :scale :initform 1 :accessor compositor-scale)
   ;; What the last frame drew, so the next frame can diff against it, and the
   ;; region that diff (plus the clients' own damage) produces (D48).
   (last-items :initform nil :accessor compositor-last-items)
   ;; Whether a frame has been drawn at all.  A separate flag because the item
   ;; list of an empty scene is NIL, which would otherwise look like "no frame
   ;; yet" and turn every frame into a full repaint (an empty output is a real
   ;; state, and repainting it costs nothing -- but knowing the difference is what
   ;; makes the damage accounting honest).
   (frame-history-p :initform nil :accessor compositor-frame-history-p)
   (damage-region :initform nil :accessor compositor-damage-region)
   ;; What the last frame changed on the screen -- its difference from the frame
   ;; before -- before any backend's own buffer staleness is merged in: :FULL, or a
   ;; region this compositor reuses, so a backend that records it must copy it
   ;; before the next frame (D61).
   (frame-change :initform :full :accessor compositor-frame-change)
   (frame-change-region :initform nil :accessor compositor-frame-change-region)
   ;; What the *clients* said they repainted this frame, with none of the compositor's
   ;; own geometry inference: the number that tells "the client repainted a band"
   ;; from "the client swapped buffers and we inferred the whole window" (D66).  :full
   ;; is only ever the compositor's answer, never a client's, so a client that damages
   ;; nothing is an empty box and not a guess.
   (client-damage :initform nil :accessor compositor-client-damage)
   (client-damage-region :initform nil :accessor compositor-client-damage-region)
   ;; How long the last frame's pixels took to draw, in milliseconds: the number that
   ;; tells a backend painting too much from a client repainting too often.  The flip
   ;; wait is the backend's own, so it is measured there and not here (D66).
   (draw-ms :initform 0.0 :accessor compositor-draw-ms)
   ;; Where the last frame painted its background: (X Y WIDTH HEIGHT), or NIL when
   ;; nothing opaque left room for it (D68).  Evidence, so "we stopped painting under
   ;; opaque windows" is a number a test reads rather than a claim in a comment.
   (background-bounds :initform :full :accessor compositor-background-bounds)
   ;; How many frames repainted less than the whole output, and the bounding box of
   ;; the last frame's damage (:full or (X Y WIDTH HEIGHT)): evidence a gate can
   ;; read instead of inferring it from timing.
   (partial-frame-count :initform 0 :accessor compositor-partial-frame-count)
   (last-damage :initform :full :accessor compositor-last-damage)
   (background :initarg :background :initform #xFF000000 :reader compositor-background)
   (target :initarg :target :accessor compositor-target)
   ;; A backend supplies the frame's destination and its presentation.  NIL is the
   ;; headless case: the target is COMPOSITOR-TARGET and presenting is nothing.
   ;; The nested backend sets both: the destination is a wl_shm buffer it owns, and
   ;; presenting is attach + damage + commit to a parent compositor.  Two function
   ;; slots keep this file from knowing what a parent is (docs/framework.md §2).
   (frame-preparer :initarg :frame-preparer :initform nil
                   :accessor compositor-frame-preparer)
   (frame-presenter :initarg :frame-presenter :initform nil
                    :accessor compositor-frame-presenter)
   ;; In commit order, which is also draw order: back to front.
   (surfaces :initform nil :accessor compositor-surfaces)
   ;; The xdg_wm_base globals this compositor created, one per client that bound
   ;; it, newest first: the gate asks them whether the ping/pong round trip and
   ;; the configure handshake really happened.
   (shells :initform nil :accessor compositor-shells)
   ;; One seat, one keymap, one modifier state (srv:seat, cf.input:modifiers).
   ;; There is no input device: a backend or a test injects what a device would
   ;; have reported, which is why the seat is reachable from the compositor.
   (seat :initarg :seat :initform nil :accessor compositor-seat)
   (modifiers :initform (input:make-modifiers) :accessor compositor-modifiers)
   ;; The windows, most recently focused first (D45).  *History*, not draw order:
   ;; it answers who gets the keys when the focused window goes away, and what
   ;; Alt+Tab visits.  Popups are never in it; a cursor surface never is.
   (focus-stack :initform nil :accessor compositor-focus-stack)
   ;; The scene: one root, one cursor, and a node per mapped surface (D31).
   ;; Positions live in the nodes, not in the surface: moving a window is the
   ;; compositor's statement, and the client's attach offset is its own.
   (scene :initarg :scene :accessor compositor-scene)
   ;; The pointer's position lives in the scene's cursor node, because that is
   ;; where it is drawn; COMPOSITOR-CURSOR-X/Y read it from there rather than
   ;; keeping a second copy that can disagree.  The seat's pointer position is
   ;; surface-local, which is a different number by design (D32).
   (cursor-visible-p :initform t :accessor compositor-cursor-visible-p)
   ;; Where the next toplevel goes: a cascade, so two windows are two windows.
   (placement-x :initform 0 :accessor compositor-placement-x)
   (placement-y :initform 0 :accessor compositor-placement-y)
   ;; The interaction that owns the pointer, if any (D33).  One at a time: a
   ;; second grab supersedes the first, which is how a move that starts during a
   ;; move ends the old one exactly once.
   (grab :initform nil :accessor compositor-grab)
   ;; Keys a binding consumed, so their releases are swallowed too: a client that
   ;; never saw the press must not see the release.
   (consumed-keys :initform nil :accessor compositor-consumed-keys)
   ;; The overlay switcher's state, if one is installed and open (D51).  An object
   ;; rather than a flag because it owns the nodes it added to the scene's overlay,
   ;; and a compositor that never binds START-SWITCHER never allocates one.
   (switcher :initform nil :accessor compositor-switcher)
   ;; Alt+Esc and Alt+F1 by default -- tinywl's two, and the smallest table that
   ;; proves the path; a compositor adds to it with CF:ADD-KEYBINDING (D33).
   (keybindings :initform nil :accessor compositor-keybindings)
   ;; client -> the wl_output resource that client bound, for wl_surface.enter.
   (outputs :initform (make-hash-table) :reader compositor-outputs)
   (dirty-p :initform t :accessor compositor-dirty-p)
   (frame-count :initform 0 :accessor compositor-frame-count))
  (:documentation
   "A headless compositor: a display with wl_compositor, wl_shm, wl_output and
xdg_wm_base, a pixman target, and the surfaces committed to it."))

(defun send-output-events (output width height &key (scale 1))
  "The initial events of the headless output, done last (docs/protocol-layer.md §8).

WIDTH and HEIGHT are layout coordinates; the mode is the hardware size, which is
those times SCALE.  A client uses wl_output.scale to decide its buffer scale, so
this one event is what makes a scale-2 output crisp instead of upscaled (D49)."
  (wl-output.geometry output 0 0 0 0 0 "cl-umbra" "headless" 0)
  (wl-output.mode output 1 (* width scale) (* height scale) 60000)
  (wl-output.scale output scale)
  (wl-output.name output "HEADLESS-1")
  (wl-output.description output "cl-compositor-framework headless output")
  (wl-output.done output))

(defun make-headless-compositor (&key (width 256) (height 256) (scale 1)
                                      (display-name (uiop:getenv "WAYLAND_DISPLAY"))
                                      (runtime-dir (uiop:getenv "XDG_RUNTIME_DIR"))
                                      (background #xFF000000)
                                      (reactor nil)
                                      (compositor-class 'headless-compositor))
  "A display offering wl_compositor, wl_shm, wl_output and xdg_wm_base, rendering
into memory.

Returns the compositor; the display is `(compositor-display ...)`, and
`(render-frame ...)` draws the current state.

COMPOSITOR-CLASS is the class of the object returned: a compositor (cl-tinywl,
cl-umbra) subclasses HEADLESS-COMPOSITOR and passes its own class, which is how
policy -- placement, what a pointer press means, what a key does -- is added to
the framework without a hook table (D7: classes, not vtables)."
  (let* ((display (srv:make-display :display-name display-name
                                               :runtime-dir runtime-dir
                                               :reactor (or reactor
                                                             (wayland.reactor:make-reactor))))
         (seat (srv:make-seat display
                              :name "seat0"
                              :capabilities (logior srv:+wl-seat-capability-pointer+
                                                    srv:+wl-seat-capability-keyboard+)))
         (scale (max 1 (round scale)))
         (compositor (make-instance compositor-class
                                    :display display
                                    :width width
                                    :height height
                                    :scale scale
                                    :background background
                                    :seat seat
                                    :scene (scene:make-scene width height :scale scale)
                                    :target (render:make-target (* width scale) (* height scale)))))
    ;; wl_compositor version 3: weston's window.c clients bind 3 unconditionally
    ;; (they were the reason this was not v1), so v3 is the lowest honest version
    ;; that lets a real pointer-using client connect.  v3 adds one request,
    ;; set_buffer_scale, which is honoured -- the output advertises the same scale
    ;; and the renderer divides a client's buffer scale back out (D49).  v4 would
    ;; promise damage_buffer.
    (srv:add-global display
                               :interface "wl_compositor"
                               :version 3
                               :resource-class 'cf-compositor
                               :bind (lambda (resource)
                                       ;; Surfaces this client creates are
                                       ;; CF-SURFACE, whose commits reach the
                                       ;; renderer (D7: configured classes).
                                       (setf (srv:compositor-surface-class resource)
                                             'cf-surface)
                                       (setf (cf-compositor-headless resource) compositor)))
    (srv:add-global display
                               :interface "wl_shm"
                               :version 1
                               :resource-class 'srv:shm
                               :bind #'srv:send-shm-formats)
    (srv:add-global display
                               :interface "wl_output"
                               :version 4
                               :resource-class 'srv:output
                               :bind (lambda (resource)
                                       (setf (gethash (srv:resource-client resource)
                                                      (compositor-outputs compositor))
                                             resource)
                                       ;; Read at bind time, not captured at start:
                                       ;; a client that binds after the output was
                                       ;; resized (a nested session following its
                                       ;; parent) must be told the size it has now.
                                       (send-output-events resource
                                                           (compositor-width compositor)
                                                           (compositor-height compositor)
                                                           :scale (compositor-scale compositor))))
    (srv:add-global display
                               :interface "xdg_wm_base"
                               :version 1
                               :resource-class 'srv:xdg-wm-base
                               :bind (lambda (resource)
                                       (setf (compositor-shells compositor)
                                             (cons resource
                                                   (compositor-shells compositor)))))
    ;; The seat is advertised at version 4 (D27): capabilities and name, keymap
    ;; and repeat_info, pointer and keyboard events.  The keymap is generated, not
    ;; compiled, so nothing here links libxkbcommon (D28).
    (srv:add-seat-global display seat)
    ;; The data device (D64).  Not a nicety: GDK binds wl_seat only once it has
    ;; seen wl_compositor *and* wl_data_device_manager, so a compositor without
    ;; this global hands every GTK client a window it cannot type into.
    (srv:add-data-device-manager-global display)
    (srv:set-seat-keymap seat (input:make-keymap) :repeat-rate 25 :repeat-delay 600)
    ;; tinywl's two bindings, installed here because this compositor is the
    ;; tinywl-shaped default (D33).  A compositor removes them or adds its own.
    (setf (compositor-keybindings compositor) (kb:make-keybinding-table))
    (add-keybinding compositor "Escape" (lambda () (stop-compositor compositor))
                    :modifiers input:+modifier-mod1+
                    :description "quit")
    (add-keybinding compositor "F1" (lambda () (cycle-views compositor))
                    :modifiers input:+modifier-mod1+
                    :description "cycle views")
    (add-keybinding compositor "Tab" (lambda () (focus-stack-cycle compositor))
                    :modifiers input:+modifier-mod1+
                    :description "cycle focus")
    (render:fill-target (compositor-target compositor) background)
    compositor))

;;; ---------------------------------------------------------------------------
;;; The scene: placement, stacking, and the node behind a surface
;;; ---------------------------------------------------------------------------
;;
;; Phase 2a drew every committed surface at its attach offset, in commit order.
;; That is not a scene: nothing could be moved, nothing could be hit-tested, and
;; "on top" meant "committed last".  v0 keeps the commit-order *list* for
;; reporting but makes the scene the thing that is drawn: a node per mapped
;; surface, with a position the compositor chooses (D31).

(defparameter +placement-step+ 32
  "How far a new toplevel steps down and right from the previous one.

tinywl places nothing at all -- every window lands on (0,0) -- and that makes
hit testing impossible to demonstrate.  A cascade is the simplest placement that
is obviously a cascade, and it starts at the origin so the first window is where
both a client and a test expect it.  A real placement policy belongs to
cl-tinywl/cl-umbra (on-new-toplevel), not to the framework's default.")

(defun advance-placement (compositor)
  "Move the cascade one step, wrapping so windows stay mostly on screen."
  (let ((limit-x (max 1 (- (compositor-width compositor) 64)))
        (limit-y (max 1 (- (compositor-height compositor) 64))))
    (setf (compositor-placement-x compositor)
          (mod (+ (compositor-placement-x compositor) +placement-step+) limit-x)
          (compositor-placement-y compositor)
          (mod (+ (compositor-placement-y compositor) +placement-step+) limit-y))))

(defgeneric on-new-toplevel (compositor surface)
  (:documentation
   "SURFACE has just mapped with a shell role: give it a node and a place.

The default gives it a cascade position and puts it on top of the stack, and is
returned through as the surface's node.  A compositor specialises this for
workspace, layout or rule-based placement (docs/framework.md §9); creating the
node and remembering it stays the framework's job either way.")
  (:method ((compositor headless-compositor) surface)
    (let ((x (compositor-placement-x compositor))
          (y (compositor-placement-y compositor)))
      (advance-placement compositor)
      (let ((node (scene:scene-add-node (compositor-scene compositor)
                                        (scene:make-buffer-node surface)
                                        :x x :y y)))
        (setf (surface-scene-node surface) node)
        (srv:log-message :debug "client ~D: surface ~D placed at (~D, ~D)"
                         (srv:client-id (srv:resource-client surface))
                         (srv:resource-id surface) x y)
        node))))

(defun popup-parent-geometry (popup)
  "Where POPUP's parent geometry starts, in output space; two values or NIL.

NIL when the parent has no scene node yet -- a popup whose toplevel has not mapped has
nothing to be placed against, and guessing (0,0) would draw a menu in the corner."
  (let* ((parent-shell (srv:xdg-popup-parent popup))
         (parent-surface (and parent-shell (srv:xdg-surface-surface parent-shell)))
         (parent-node (and parent-surface (surface-scene-node parent-surface))))
    (when parent-node
      (multiple-value-bind (geometry-x geometry-y width height)
          (grab:node-geometry parent-node)
        (declare (ignore width height))
        (values (+ (scene:node-x parent-node) geometry-x)
                (+ (scene:node-y parent-node) geometry-y))))))

(defun sync-popup-node (surface)
  "Put SURFACE's popup node where its configure and its parent say it belongs.

Asked every frame (SYNC-POPUP-POSITIONS) rather than only when the configure
arrives: the parent can move under the popup -- a drag, a resize, a cycle -- and a
menu that does not follow its window is a menu over the wrong thing.  That is the
same rule as the pointer's image (D41): ask, do not be told."
  (let* ((node (surface-scene-node surface))
         (shell (srv:surface-shell-surface surface))
         (popup (and shell (srv:xdg-surface-role shell))))
    (when (and node (typep popup 'srv:xdg-popup))
      (let ((geometry (srv:xdg-popup-geometry popup)))
        (when geometry
          (multiple-value-bind (parent-x parent-y) (popup-parent-geometry popup)
            (when parent-x
              (destructuring-bind (x y width height) geometry
                (declare (ignore width height))
                ;; The configure's (x, y) is the popup's *window geometry* origin;
                ;; the node draws the buffer, which may start earlier (a shadow).
                (multiple-value-bind (own-x own-y) (grab:node-geometry node)
                  (scene:set-node-position node
                                           (- (+ parent-x x) own-x)
                                           (- (+ parent-y y) own-y)))))))))))

(defun sync-popup-positions (compositor)
  "Re-place every mapped popup.  Called once per frame, before the draw."
  (dolist (surface (compositor-surfaces compositor))
    (when (srv:surface-mapped-p surface)
      (let ((shell (srv:surface-shell-surface surface)))
        (when (and shell (eq :popup (srv:xdg-surface-role-name shell)))
          (sync-popup-node surface))))))

(defun popup-nodes-of (compositor node)
  "The nodes of NODE's window's popups, bottom to top (the protocol's stacking)."
  (declare (ignore compositor))
  (let* ((surface (and (typep node 'scene:buffer-node) (scene:buffer-node-surface node)))
         (shell (and surface (srv:surface-shell-surface surface)))
         (toplevel (and shell (srv:xdg-surface-role shell))))
    (when (typep toplevel 'srv:xdg-toplevel)
      (loop for popup in (srv:xdg-toplevel-popups toplevel)
            for popup-surface = (let ((popup-shell (srv:xdg-popup-shell-surface popup)))
                                  (and popup-shell (srv:xdg-surface-surface popup-shell)))
            for popup-node = (and popup-surface (surface-scene-node popup-surface))
            when popup-node collect popup-node))))

(defun raise-window-with-popups (compositor node)
  "Raise NODE, and keep its window's popups above it; returns NODE.

A menu is not a window with its own place in the stack: it belongs to the window it
dropped from.  Raising the window alone would bury its menu; raising the menu alone
would be true only until the next click raised the window."
  (scene:node-raised node)
  (dolist (popup-node (popup-nodes-of compositor node))
    (scene:node-raised popup-node))
  node)

(defgeneric on-new-popup (compositor surface popup)
  (:documentation
   "SURFACE has just mapped with the popup role: give it a node, where its
configure and its parent say it goes.

The default places it at the parent's window-geometry origin plus the configure's
(x, y) -- the position the protocol layer already computed and sent -- and puts it on
top of the stack.  Creating the node and remembering it stays the framework's job; a
compositor specialises this only to change *where* a child window belongs
(docs/framework.md §9).")
  (:method ((compositor headless-compositor) surface popup)
    (let ((node (scene:scene-add-node (compositor-scene compositor)
                                      (scene:make-buffer-node surface))))
      (setf (surface-scene-node surface) node)
      (sync-popup-node surface)
      ;; A menu belongs above the window it drops from, and a new popup is above
      ;; every older one (the protocol's own stacking rule).
      (raise-window-with-popups compositor node)
      (srv:log-message :debug "client ~D: popup ~D placed at (~D, ~D)"
                       (srv:client-id (srv:resource-client surface))
                       (srv:resource-id surface)
                       (scene:node-x node) (scene:node-y node))
      node)))

(defun cursor-surface-p (compositor surface)
  "Is SURFACE the pointer image some client has installed right now?

v0 draws its own cursor and does not composite a client's -- cursor surfaces are
phase 5 -- so the seat's record of what was offered is what keeps it out of the
scene.  Two things make that record necessary and neither is optional: such a
surface has no shell role, so it takes the roleless path (a node at the scene
origin, drawn where the client's attach offset says); and it is hit-testable and
first in stack order, which is where a cycling or click-to-focus policy would find
it and raise a tiny arrow instead of a window.

This answers 'is it the cursor *now*'.  SURFACE-POINTER-IMAGE-P is the durable
version, and the pair covers the ordering hole: a client may commit a cursor
surface before it names it, at which point nothing here can know yet (D40)."
  (let ((seat (compositor-seat compositor)))
    (loop for binding in (srv:seat-bindings seat)
          thereis (loop for pointer in (srv:seat-resource-pointers binding)
                        thereis (eq (srv:pointer-cursor-surface pointer) surface)))))

(defmethod srv:seat-cursor-changed ((seat srv:seat) pointer (surface cf-surface))
  "Record that SURFACE is a cursor image, and take back any node it already has.

wl_pointer.set_cursor is the only moment a surface is named as the pointer's
image, and it can arrive *after* that surface's first mapped commit -- the protocol
applies the image at the next commit, so both orders are legal.  A client that
commits first gets a node from the roleless path, and a node is a permanent
invitation to be drawn: the image then sits at the output's origin, updating
whenever the client changes its cursor, which is the stray cursor the fourth manual
test found (D40).  So the flag is set here, for good, and the node is withdrawn."
  (declare (ignore pointer))
  (setf (surface-pointer-image-p surface) t)
  (let ((compositor (and (srv:surface-owner surface)
                         (cf-compositor-headless (srv:surface-owner surface)))))
    (when (and compositor (surface-scene-node surface))
      (forget-surface compositor surface)))
  nil)

(defun ensure-scene-node (compositor surface)
  "The node SURFACE is drawn through, creating it on the first mapped commit.

A surface with a shell role is placed by ON-NEW-TOPLEVEL.  A bare wl_surface has
no role and no compositor policy about where it goes, so its node stays at the
scene origin and its attach offset -- the client's own statement about its
content -- puts its pixels where the client asked.  That is exactly what phase 2a
did, and the shm gate still checks it pixel by pixel.  A cursor surface gets no
node at all (CURSOR-SURFACE-P, SURFACE-POINTER-IMAGE-P)."
  (let ((node (surface-scene-node surface)))
    (unless node
      (unless (or (surface-pointer-image-p surface)
                  (cursor-surface-p compositor surface))
        (let* ((shell (srv:surface-shell-surface surface))
               (role-name (and shell (srv:xdg-surface-role-name shell))))
          (setf node
                (cond
                  ;; A window is placed by policy; a popup is placed by the
                  ;; protocol's own answer (ON-NEW-POPUP); a bare surface is
                  ;; where its attach offset says.
                  ((eq role-name :toplevel)
                   (on-new-toplevel compositor surface))
                  ((eq role-name :popup)
                   (on-new-popup compositor surface (srv:xdg-surface-role shell)))
                  (t
                   ;; A roleless surface records its own node here.  It used
                   ;; not to, and the node was then invisible to everything
                   ;; that finds a surface's node by looking at the surface:
                   ;; PRUNE-SURFACES could not remove it when the surface
                   ;; unmapped, and a cursor image that had been given one
                   ;; could not be taken back (D40).
                   (setf (surface-scene-node surface)
                         (scene:scene-add-node (compositor-scene compositor)
                                               (scene:make-buffer-node surface)))))))))
    ;; Committing is not raising.  Phase 2a used commit order as draw order, which
    ;; made two redrawing clients flip places several times a second; stacking is
    ;; the compositor's decision, and v0's decision is "the order windows were
    ;; placed in".  RAISE-WINDOW-WITH-POPUPS is what a click-to-raise policy calls.
    node))

(defun mark-dirty (compositor)
  "The output needs a frame; arrange one render at the end of this cycle.

One render per cycle however many commits or pointer moves arrived in it (D24),
and the flush after it, because frame callbacks and cursor moves produce events
outside any client's readable event (D27)."
  (setf (compositor-dirty-p compositor) t)
  (reactor:add-idle
   (srv:display-reactor (compositor-display compositor))
   (lambda ()
     (when (compositor-dirty-p compositor)
       (render-frame compositor)
       (srv:flush-all (compositor-display compositor))))))

(defun request-frame (compositor)
  "Ask for a frame at the end of this reactor cycle.

MARK-DIRTY's public name: a backend that owns the frame clock (nested: a parent
buffer came free, or the parent's frame callback arrived) uses it to say that there is
something to draw now, without reaching into the compositor's state."
  (mark-dirty compositor))

;;; ---------------------------------------------------------------------------
;;; Commit: what a compositor does about it
;;; ---------------------------------------------------------------------------

(defmethod srv:surface-committed ((surface cf-surface) damage)
  "Mark the output dirty, remember what the client damaged, arrange one render.

DAMAGE is the rectangles the client itself said changed, in surface-local
coordinates.  They are kept on the surface until a frame paints them, because a
frame is the only thing that knows where the surface is *now* -- the mapping to
output pixels happens once per frame, in the scene (D48).  A commit with no damage
at all (a client that only changed a region, or destroyed a callback) damages
nothing: the frame that follows it has nothing to draw and will not draw it."
  (let* ((compositor (cf-compositor-headless (srv:surface-owner surface))))
    (unless (member surface (compositor-surfaces compositor))
      (setf (compositor-surfaces compositor)
            (append (compositor-surfaces compositor) (list surface))))
    (when (srv:surface-mapped-p surface)
      ;; Whether this is the surface's first *mapped* commit is what decides
      ;; focus, not whether it happens to be focused now: with two windows, a
      ;; "focus if not focused" rule hands the keyboard to whichever client
      ;; committed last, which is a fight, not a policy (found by the scene gate
      ;; with two real clients).
      (let ((first-map (null (surface-scene-node surface))))
        (ensure-scene-node compositor surface)
        ;; tinywl's policy, and the only one that can exist without a focus
        ;; stack: a window that *maps* takes the keyboard, so the client learns it
        ;; is activated and the keys it asked for arrive (D27).  Once per map.
        (when (and first-map (srv:surface-shell-surface surface))
          (focus-surface compositor surface))))
    ;; A resize from the top or left edge keeps the *opposite* edge still, and what
    ;; decides where the node goes is the size the client actually came back with --
    ;; so this is the moment to place it (D42).
    (let ((grab (compositor-grab compositor)))
      (when (and grab
                 (typep (grab:grab-node grab) 'scene:buffer-node)
                 (eq (scene:buffer-node-surface (grab:grab-node grab)) surface))
        (grab:grab-anchored grab)))
    ;; What the client says it changed, unioned with what it said before: two
    ;; commits between frames are two damages, and the frame owes both.
    (when damage
      (setf (surface-content-damage surface)
            (append damage (surface-content-damage surface))))
    (mark-dirty compositor)
    surface))

;;; ---------------------------------------------------------------------------
;;; Focus and synthetic input
;;; ---------------------------------------------------------------------------
;;
;; There is no libinput here: a *backend* reports what a device did, and a
;; compositor decides who hears it.  These functions are that seam, and they are
;; also how the gate drives real clients, which is why they are exported rather
;; than kept behind a test-only door.  The pointer's position is output space;
;; the seat's is surface-local, and the scene converts one into the other (D32).

(defun compositor-cursor-x (compositor)
  "The pointer's X in output space: the cursor node's position."
  (scene:node-x (scene:scene-cursor (compositor-scene compositor))))

(defun compositor-cursor-y (compositor)
  "The pointer's Y in output space: the cursor node's position."
  (scene:node-y (scene:scene-cursor (compositor-scene compositor))))

(defun surface-under-cursor (compositor)
  "The surface under the pointer, and the position in its own coordinates.

NIL when the pointer is over the bare output -- including over a RECT-NODE, since
a background is not something that can be clicked.  This is the framework's
`desktop_view_at' (docs/framework.md §4), one layer deep."
  (multiple-value-bind (node x y)
      (scene:scene-hit-test (compositor-scene compositor)
                            (compositor-cursor-x compositor)
                            (compositor-cursor-y compositor))
    (when (and node (typep node 'scene:buffer-node))
      (values (scene:buffer-node-surface node) x y))))

(defun update-pointer (compositor)
  "Point the seat at whatever is under the cursor.

Pointer focus follows the *pointer*, not the keyboard: moving across a window
sends it enter/motion without moving the keys, because a hover must not steal
focus and a click must not require one (D32)."
  (let ((seat (compositor-seat compositor)))
    (multiple-value-bind (surface x y) (surface-under-cursor compositor)
      (cond
        ;; A drag owns the pointer while it is in flight (D64): no client hears
        ;; wl_pointer, and the surface under the pointer hears wl_data_device
        ;; instead -- enter, motion and drop, which is how a drop target learns
        ;; what is being dragged over it.
        ((srv:data-drag-active-p seat)
         (when (srv:seat-pointer-focus seat)
           (srv:set-pointer-focus seat nil 0 0))
         (srv:update-data-drag seat surface x y))
        ((null surface)
         (when (srv:seat-pointer-focus seat)
           (srv:set-pointer-focus seat nil 0 0)))
        ((eq surface (srv:seat-pointer-focus seat))
         (srv:send-pointer-motion seat x y))
        (t
         (srv:set-pointer-focus seat surface x y))))))

(defun seat-pointer-cursor-image (seat)
  "The cursor image of the pointer whose client has pointer focus.

Returns (values surface hotspot-x hotspot-y), or NIL.  Focus, not 'any pointer with an
image': every client installs a cursor when the pointer enters it and may keep it, so
the only image that means anything is the one belonging to the client the pointer is
over (D41)."
  (let ((focus (srv:seat-pointer-focus seat)))
    (when focus
      (let ((client (srv:resource-client focus)))
        (loop for binding in (srv:seat-bindings seat)
              do (loop for pointer in (srv:seat-resource-pointers binding)
                       when (and (eq client (srv:resource-client pointer))
                                 (srv:pointer-cursor-surface pointer))
                         do (return-from seat-pointer-cursor-image
                              (values (srv:pointer-cursor-surface pointer)
                                      (srv:pointer-cursor-hotspot-x pointer)
                                      (srv:pointer-cursor-hotspot-y pointer))))))))
  nil)

(defun sync-cursor-image (compositor)
  "Point the scene's cursor at the image the focused client has installed.

There is no event that says \"the pointer's picture changed and a frame is due\" -- a
client may name an image and never commit anything, and a client that hides its cursor
sends nothing at all -- so the frame path asks instead of being told.  That is one
comparison per frame, and it cannot go stale the way a missed event would: a motion
always produces the next frame, and the next frame is the one that would have shown
the wrong picture (D41)."
  (let ((scene (compositor-scene compositor)))
    (multiple-value-bind (surface hotspot-x hotspot-y)
        (seat-pointer-cursor-image (compositor-seat compositor))
      (unless (and (eq surface (scene:scene-cursor-surface scene))
                   (eql (or hotspot-x 0) (scene:scene-cursor-hotspot-x scene))
                   (eql (or hotspot-y 0) (scene:scene-cursor-hotspot-y scene)))
        (setf (scene:scene-cursor-surface scene) surface
              (scene:scene-cursor-hotspot-x scene) (or hotspot-x 0)
              (scene:scene-cursor-hotspot-y scene) (or hotspot-y 0))
        (setf (compositor-dirty-p compositor) t)))))

;;; ---------------------------------------------------------------------------
;;; The focus stack (D45)
;;;
;;; Two orders that are not the same order.  The scene's children are *draw* order:
;;; what covers what.  The focus stack is *history*: who had the keyboard, most
;;; recently first.  A compositor needs both, and conflating them leaves it without
;;; an answer to "who gets the keys when this window closes" -- "the one that
;;; mapped last" is not an answer once a second window exists.
;;;
;;; What goes in it: windows (the toplevel role).  Never popups: a popup is
;;; transient and takes the keyboard while it is up (the spec says the topmost
;;; grabbing popup always has focus), but a menu in the stack would be something
;;; Alt+Tab could return to after it had gone.  Focusing a popup therefore pushes
;;; the window it belongs to, because that window is the active window.
;;; ---------------------------------------------------------------------------

(defun focus-stack-window (surface)
  "The window a focus event about SURFACE is really about, or NIL.

A window is itself; a popup is the window its toplevel belongs to; a roleless
surface -- a cursor image, a bare surface a client mapped for itself -- is nobody's."
  (let* ((shell (and surface (srv:surface-shell-surface surface)))
         (role (and shell (srv:xdg-surface-role shell))))
    (cond
      ((null shell) nil)
      ((window-surface-p surface) surface)
      ((typep role 'srv:xdg-popup)
       (let* ((toplevel (srv:xdg-popup-toplevel role))
              (toplevel-shell (and toplevel (srv:xdg-toplevel-shell-surface toplevel))))
         (and toplevel-shell (srv:xdg-surface-surface toplevel-shell))))
      (t nil))))

(defun focus-stack-note (compositor surface)
  "SURFACE was just focused: move its window to the front of the stack."
  (let ((window (focus-stack-window surface)))
    (when window
      (setf (compositor-focus-stack compositor)
            (cons window (remove window (compositor-focus-stack compositor) :test #'eq))))
    window))

(defun focus-stack-forget (compositor surface)
  "Drop SURFACE from the stack; returns the stack's remaining front, or NIL."
  (setf (compositor-focus-stack compositor)
        (remove surface (compositor-focus-stack compositor) :test #'eq))
  (first (compositor-focus-stack compositor)))

(defun focusable-window-p (surface)
  "Can SURFACE take the keyboard right now: alive, mapped, and a window?"
  (and surface
       (not (srv:resource-destroyed-p surface))
       (srv:surface-mapped-p surface)
       (focus-stack-window surface)))

(defun window-title (surface)
  "SURFACE's window title: the client's title, else its app id, else NIL.

The title is what a person reads, in a switcher or a bar.  The app id is what the
client says it *is*, and it is the honest second choice: a client that sets no
title -- every toy-toolkit example, and weston-simple-shm -- still has a name.
NIL is `this surface has no window name': a popup, a roleless surface, or a
surface whose role is not a toplevel.  Deciding what to draw for NIL is the
caller's job, and the switcher's is a stand-in word (D51)."
  (let* ((shell (and surface (srv:surface-shell-surface surface)))
         (role (and shell (srv:xdg-surface-role shell))))
    (when (typep role 'srv:xdg-toplevel)
      (flet ((named (string) (and (stringp string) (plusp (length string)) string)))
        (or (named (srv:xdg-toplevel-title role))
            (named (srv:xdg-toplevel-app-id role)))))))

(defun focus-surface (compositor surface)
  "Give keyboard focus to SURFACE; NIL clears it.

One call, because keyboard enter/leave and the toplevel's activated configure
must not drift apart (D27).  The pointer is moved onto SURFACE only when the
cursor is actually over it: keyboard focus and pointer focus are different
questions, and a window that maps under a resting pointer must not teleport it
(D31).  A compositor that wants hover-to-focus calls UPDATE-POINTER from its
motion handling instead."
  (let ((seat (compositor-seat compositor)))
    (srv:set-keyboard-focus seat surface)
    ;; Whatever the focus was *about* -- a window, or the window a menu belongs to
    ;; -- is now the most recently focused one (D45).
    (focus-stack-note compositor surface)
    (multiple-value-bind (under x y) (surface-under-cursor compositor)
      (cond ((null surface)
             (srv:set-pointer-focus seat nil 0 0))
            ((eq under surface)
             (srv:set-pointer-focus seat surface x y))))
    surface))

(defmethod srv:seat-focus-changed ((seat srv:seat) surface has-focus)
  "Tell an xdg_toplevel it is activated or not.

The state array is recomputed on every configure, never patched, so a losing
toplevel gets an empty array rather than a stale `activated`.  A popup has no
activated state and no xdg_toplevel object: asking one for its activated configure
would be a type error at the worst possible moment (the click that focuses a menu)."
  (let* ((shell (and surface (srv:surface-shell-surface surface)))
         (role (and shell (srv:xdg-surface-role shell))))
    (when (typep role 'srv:xdg-toplevel)
      (srv:set-toplevel-activated role has-focus)))
  nil)

;;; ---------------------------------------------------------------------------
;;; Keybindings
;;; ---------------------------------------------------------------------------
;;
;; The key path is the backend seam plus one rule: a binding is consulted before
;; the focused client, and a consumed key never reaches it.  v0 has no device to
;; suppress a modifier from, so a modifier that is not itself bound still goes to
;; the client -- a client that never saw Alt release would think it was held.

(defun add-keybinding (compositor key function &key (modifiers 0) description)
  "Bind KEY with MODIFIERS to FUNCTION in COMPOSITOR's table."
  (kb:add-keybinding (compositor-keybindings compositor) key function
                     :modifiers modifiers :description description))

(defun remove-keybinding (compositor key &key (modifiers 0))
  "Drop COMPOSITOR's binding for KEY; returns true when one was there."
  (kb:remove-keybinding (compositor-keybindings compositor) key :modifiers modifiers))

(defun stop-compositor (compositor)
  "Ask the main loop to stop at the end of this cycle (tinywl's Alt+Esc)."
  (reactor:request-stop (srv:display-reactor (compositor-display compositor))))

;;; ---------------------------------------------------------------------------
;;; The switcher's two seams (D51)
;;; ---------------------------------------------------------------------------
;;
;; A switcher is modal while a key is *held*, which a binding table cannot express:
;; a binding fires on a press, and a switcher has to see the release that commits it
;; and every key in between.  So the key path asks the compositor's switcher first --
;; in front of grabs and bindings, because a held Alt+Tab is the compositor's
;; decision and no menu may take it away -- and the state behind the answer lives in
;; CF.SWITCHER's object in COMPOSITOR-SWITCHER.
;;
;; Two generic functions with no-op defaults, so a compositor with no switcher pays
;; one dispatch per key and keeps none of this code in its key path.

(defgeneric switcher-key (compositor name state)
  (:documentation
   "COMPOSITOR's switcher takes the key called NAME (:pressed or :released)?

Asked before grabs, bindings and the focused client.  True means the key was
consumed -- by the switcher, or by the release that committed it -- so the client
must not see it.  The default has no switcher and takes nothing.")
  (:method (compositor name state)
    (declare (ignore compositor name state))
    nil))

(defgeneric switcher-pointer-press (compositor)
  (:documentation
   "A pointer button went down over COMPOSITOR: an overlay it was showing is now the
wrong thing to be showing.

The default has no overlay, so it does nothing.  A switcher that ignored the press
would leave two things believing they are choosing the window at once.")
  (:method (compositor)
    (declare (ignore compositor))
    nil))

(defun window-surface-p (surface)
  "Is SURFACE a window: a wl_surface with the *toplevel* role?

Not every surface is a window.  A client's cursor image has no role at all, a popup
has a role but no window of its own, and so has any surface a client maps for itself;
cycling, click-to-raise or re-clamping that treated those as windows would raise an
arrow or move a menu (D36, D44, D46)."
  (let ((shell (and surface (srv:surface-shell-surface surface))))
    (and shell (eq :toplevel (srv:xdg-surface-role-name shell)))))

(defun window-node-p (node)
  "Is NODE a window: a mapped surface with the toplevel role?"
  (and (typep node 'scene:buffer-node)
       (window-surface-p (scene:buffer-node-surface node))))

(defun cycle-views (compositor)
  "Bring the bottom window to the top and give it the keyboard (tinywl's Alt+F1).

The bottom is draw order, so cycling visits every window once and the old one ends
up at the back -- the same rule tinywl's view list has.  A window's popups travel
with it, or a menu would be left behind over whatever is now on top."
  (let* ((root (scene:scene-root (compositor-scene compositor)))
         (windows (remove-if-not #'window-node-p (scene:node-children root))))
    (when windows
      (let ((node (first windows)))
        (raise-window-with-popups compositor node)
        (focus-surface compositor (scene:buffer-node-surface node))
        (mark-dirty compositor)
        node))))

(defun focus-stack-cycle (compositor)
  "Focus and raise the *least* recently focused window (Alt+Tab's job).

The tail of the stack, rotated to the front, so a full cycle visits every window
exactly once and two windows toggle.  A rotating cycle rather than an MRU toggle:
with three windows a toggle can never reach the third, and a hold-Tab-release
switcher needs an overlay to show what is selected -- a scene node, which is phase
6's business.  The same list will serve it.

The raise is part of this function's contract, not of FOCUS-SURFACE's: a focus cycle
that does not show the window it chose is invisible, and stacking is policy (D31) --
so the policy function raises and the primitive does not.  Returns the window it
focused, or NIL when there is nothing to cycle to."
  (let* ((live (remove-if-not #'focusable-window-p (compositor-focus-stack compositor)))
         (next (car (last live))))
    ;; A window can be in the stack and no longer mapped for one frame (a commit and
    ;; a key in the same batch); drop those rather than focus something invisible.
    (setf (compositor-focus-stack compositor) live)
    (when next
      (focus-surface compositor next)
      (let ((node (surface-scene-node next)))
        (when node (raise-window-with-popups compositor node)))
      (mark-dirty compositor)
      next)))

(defun end-active-grab (compositor &key reason)
  "End COMPOSITOR's grab, if it has one; idempotent."
  (let ((grab (compositor-grab compositor)))
    (if grab
        (grab:grab-end grab :reason (or reason :requested))
        nil)))

(defun start-grab (compositor grab)
  "Make GRAB the interaction that owns the pointer, ending any previous one."
  (let ((old (compositor-grab compositor)))
    (when old
      (grab:grab-end old :reason :superseded)))
  (setf (grab:grab-owner grab) compositor
        (compositor-grab compositor) grab)
  (srv:log-message :debug "grab started: ~A" (class-name (class-of grab)))
  grab)

(defmethod grab:grab-ended ((grab grab:grab) reason)
  "The compositor forgets a grab that ended, whoever ended it."
  (declare (ignore reason))
  (let ((compositor (grab:grab-owner grab)))
    (when (and compositor (eq grab (compositor-grab compositor)))
      (setf (compositor-grab compositor) nil))))

(defmethod grab:grab-changed ((grab grab:grab))
  (let ((compositor (grab:grab-owner grab)))
    (when compositor (mark-dirty compositor))))

(defmethod grab:grab-resize ((grab grab:resize-grab) width height)
  "Ask the client for a new size: for a shm client, that is what resizing is.

A grab whose node is not a surface -- a rectangle in a test, or a future node kind
without a client behind it -- has no one to ask, so it asks nothing."
  (let ((node (grab:grab-node grab)))
    (when (typep node 'scene:buffer-node)
      (let* ((surface (scene:buffer-node-surface node))
             (shell (and surface (srv:surface-shell-surface surface)))
             (toplevel (and shell (srv:xdg-surface-role shell))))
        (when (typep toplevel 'srv:xdg-toplevel)
          (srv:request-toplevel-size toplevel width height))))))

(defun handle-key (compositor name state)
  "Press or release the key called NAME (:pressed or :released).

The modifier mask is updated from the keymap's own table first, so a binding sees
the mask the press produced; then a switcher, a grab, a binding, and only then the
focused client."
  (let* ((seat (compositor-seat compositor))
         (modifiers (compositor-modifiers compositor))
         (pressed-p (eq state :pressed))
         (grab (compositor-grab compositor)))
    (input:update-modifiers modifiers name pressed-p)
    (cond
      ;; Escape abandons a drag (D64), before a grab or a binding can claim it:
      ;; a drag that cannot be cancelled by the key everybody expects is a drag
      ;; that ends up dropped somewhere nobody meant.
      ((and pressed-p (srv:data-drag-active-p seat)
            (string-equal name "Escape"))
       (srv:cancel-data-drag seat)
       (push name (compositor-consumed-keys compositor))
       t)
      ;; A held-switcher key is compositor state, not a client's input: it is asked
      ;; first, before any grab, because a menu that swallowed Alt+Tab would make
      ;; the switcher unreachable exactly when a menu is up (D51).
      ((switcher-key compositor name state)
       ;; The same bookkeeping a binding does: a key the switcher consumed must not
       ;; have its release delivered to a client that never saw its press.
       (if pressed-p
           (push name (compositor-consumed-keys compositor))
           (setf (compositor-consumed-keys compositor)
                 (remove name (compositor-consumed-keys compositor)
                         :test #'string-equal)))
       t)
      ((and grab (grab:grab-key grab name state))
       t)
      ((and pressed-p
            (kb:dispatch-keybinding (compositor-keybindings compositor)
                                    name (input:modifiers-depressed modifiers)))
       (push name (compositor-consumed-keys compositor))
       t)
      ((and (not pressed-p)
            (member name (compositor-consumed-keys compositor) :test #'string-equal))
       (setf (compositor-consumed-keys compositor)
             (remove name (compositor-consumed-keys compositor) :test #'string-equal))
       t)
      (t
       (srv:send-key-event seat (input:keycode name) state
                           :mods-depressed (input:modifiers-depressed modifiers)
                           :mods-latched (input:modifiers-latched modifiers)
                           :mods-locked (input:modifiers-locked modifiers)
                           :group (input:modifiers-group modifiers))))))

(defun inject-key (compositor name state)
  "SYNTHETIC key press or release; same path a real backend's device takes."
  (handle-key compositor name state))

(defun clamp-pointer (compositor x y)
  "A grab's copy of the pointer position, clamped into the output; two values.

A drag past an edge still means something on the other axis: a person dragging a
window's bottom-right corner past the bottom of the screen expects it to keep growing
to the right, not to stop growing at all (D47).  Only the *grab* sees the clamped
position; the cursor node keeps the coordinates the device reported (D43)."
  (values (max 0 (min x (max 0 (1- (compositor-width compositor)))))
          (max 0 (min y (max 0 (1- (compositor-height compositor)))))))

(defun inject-pointer-motion (compositor x y)
  "Move the pointer to (X, Y) in output space and let the scene decide who hears it.

While a grab holds the pointer the grab decides: the client under the pointer is not
sent motion events for a drag it is not doing.  A position outside the output is
*clamped* for the grab rather than ending it (CLAMP-POINTER, D47): the device still
belongs to this compositor, so a drag whose pointer is past one edge keeps tracking
the other.  What ends a grab is the backend saying the pointer is gone --
INJECT-POINTER-LEAVE, which is exactly what a nested session learns when its parent
takes the pointer away (D43), and the one case where nothing can continue."
  (scene:set-node-position (scene:scene-cursor (compositor-scene compositor)) x y)
  (let ((grab (compositor-grab compositor)))
    (if (null grab)
        (update-pointer compositor)
        (multiple-value-bind (grab-x grab-y) (clamp-pointer compositor x y)
          (grab:grab-motion grab grab-x grab-y))))
  ;; The cursor moved, so the frame changed even if no client did anything.
  (mark-dirty compositor))

(defun inject-pointer-leave (compositor)
  "The pointer is no longer over the output at all: park it, drop the focus, end a grab.

This is a backend's *statement*, not an inference from a coordinate: a nested session
receives wl_pointer.leave from its parent when the outer pointer walks off its window,
and after that event it gets no coordinates at all, so a drag cannot continue however
much of it was still meaningful.  Ending the grab here is what stops a nested session
from swallowing the mouse -- the failure D43 was written for -- and it is the one case
where 'the pointer is outside' really does mean 'there is no pointer any more'."
  (scene:set-node-position (scene:scene-cursor (compositor-scene compositor)) -1 -1)
  (when (compositor-grab compositor)
    (end-active-grab compositor :reason :pointer-left-output))
  (update-pointer compositor)
  (mark-dirty compositor))

(defparameter +pointer-buttons+
  '((:left . #x110) (:right . #x111) (:middle . #x112)))

;;; ---------------------------------------------------------------------------
;;; Who a pointer press belongs to
;;; ---------------------------------------------------------------------------
;;
;; The framework's rule is "the window under the pointer takes the keyboard on a
;; press, and then the client hears the click".  That is one policy among several
;; -- a compositor that binds Alt+drag to move has to see the press first, and a
;; click-to-raise compositor has to raise before the client redraws -- so the
;; decision is a generic function dispatched on the compositor, like
;; ON-NEW-TOPLEVEL, and policy is added by subclassing (D7, D36).

(defgeneric on-pointer-button (compositor button state)
  (:documentation
   "BUTTON (:left, :right, :middle, or a numeric evdev code when a backend
reports a button we have no name for) was pressed or released over COMPOSITOR,
with no grab active.

The default method focuses the window under the pointer on a press and forwards
the event to the client.  A compositor specialises this for the presses it wants
for itself (a modifier drag, click-to-raise) and calls CALL-NEXT-METHOD for the
ones it does not: an event this method does not send is an event the client never
sees, and a client that never saw a press must not see its release.")
  (:method ((compositor headless-compositor) button state)
    (let ((seat (compositor-seat compositor))
          (code (or (cdr (assoc button +pointer-buttons+)) button)))
      ;; A drag in flight swallows the button (D64): the release is the drop, and
      ;; the press that is still down belongs to whoever started the drag.
      (when (srv:data-drag-active-p seat)
        (when (eq state :released)
          (srv:finish-data-drag seat))
        (return-from on-pointer-button t))
      (when (eq state :pressed)
        (multiple-value-bind (surface x y) (surface-under-cursor compositor)
          (when surface
            (unless (eq surface (srv:seat-pointer-focus seat))
              (srv:set-pointer-focus seat surface x y))
            (unless (eq surface (srv:seat-keyboard-focus seat))
              (focus-surface compositor surface)))))
      (srv:send-pointer-button seat code state))))

;;; ---------------------------------------------------------------------------
;;; A client asking to be moved or resized
;;; ---------------------------------------------------------------------------
;;
;; The shell has already checked the serial and the focus (D33); what is left is
;; this compositor's policy, and the policy is "start a grab".
;;
;; The grab holds the button that is *physically down* rather than assuming the
;; left one: a client may ask from a middle-button drag, and a grab that ends on
;; the wrong button would either end immediately or never.

(defun dragged-button (compositor)
  "The button that is physically down, or NIL when none is.

A move or resize request is only meaningful while its button is held: the grab ends
on that button's release.  A request that arrives with nothing down describes an
interaction that is already over -- a click whose press and release were read in one
dispatch, which is exactly what injected input does -- and starting a grab for it
leaves the pointer owned by a drag nobody is making, so the next click goes to the
grab instead of to the window."
  (first (srv:seat-pressed-buttons (compositor-seat compositor))))

(defmethod srv:toplevel-move-requested ((surface cf-surface) toplevel serial seat)
  "A validated xdg_toplevel.move: start an interactive move of this window."
  (declare (ignore seat))
  (let* ((compositor (cf-compositor-headless (srv:surface-owner surface)))
         (node (surface-scene-node surface))
         (button (dragged-button compositor)))
    (cond
      ((null node)
       (srv:log-message :debug "toplevel ~D asked to move but has no scene node"
                        (srv:resource-id toplevel))
       nil)
      ((null button)
       (srv:log-message :debug "toplevel ~D asked to move with no button down"
                        (srv:resource-id toplevel))
       nil)
      (t
       (start-grab compositor
                   (grab:begin-move-grab node
                                         (compositor-cursor-x compositor)
                                         (compositor-cursor-y compositor)
                                         :button button
                                         ;; A move is clamped to the output: a window
                                         ;; dragged out of reach is a window lost (D43).
                                         :output-width (compositor-width compositor)
                                         :output-height (compositor-height compositor)))
       (srv:log-message :debug "toplevel ~D: interactive move (serial ~D)"
                        (srv:resource-id toplevel) serial)
       t))))

(defmethod srv:toplevel-resize-requested ((surface cf-surface) toplevel serial seat edges)
  "A validated xdg_toplevel.resize: start an interactive resize from EDGES."
  (declare (ignore seat))
  (let* ((compositor (cf-compositor-headless (srv:surface-owner surface)))
         (node (surface-scene-node surface))
         (button (dragged-button compositor)))
    (cond
      ((null node)
       (srv:log-message :debug "toplevel ~D asked to resize but has no scene node"
                        (srv:resource-id toplevel))
       nil)
      ((null button)
       (srv:log-message :debug "toplevel ~D asked to resize with no button down"
                        (srv:resource-id toplevel))
       nil)
      (t
       (start-grab compositor
                   (grab:begin-resize-grab node
                                           (compositor-cursor-x compositor)
                                           (compositor-cursor-y compositor)
                                           edges
                                           :button button
                                           :min-width (max 1 (srv:xdg-toplevel-min-width toplevel))
                                           :min-height (max 1 (srv:xdg-toplevel-min-height toplevel))
                                           ;; A resize stops at the output, like a move (D46).
                                           :output-width (compositor-width compositor)
                                           :output-height (compositor-height compositor)))
       (srv:log-message :debug "toplevel ~D: interactive resize (serial ~D, edges ~D)"
                        (srv:resource-id toplevel) serial edges)
       t))))

(defun inject-pointer-button (compositor button state)
  "SYNTHETIC pointer button (:left, :right, :middle), pressed or released.

Three rules, in this order.  A press ends an overlay the compositor was showing --
a click says the switcher was not what was wanted (D51).  A grab owns the pointer
while one is active: the grab decides, and the event is not also delivered as a
click to the client under it.  With no grab, the compositor's own policy decides
(`on-pointer-button`), which by default means -- D32 -- a press focuses the window
under the pointer (the click that makes clicking another window work at all) and
the client then hears it.  A press on the bare output changes nothing: v0 has no
click-to-dismiss policy."
  (when (eq state :pressed)
    (switcher-pointer-press compositor))
  (let ((grab (compositor-grab compositor)))
    (if grab
        (grab:grab-button grab (or (cdr (assoc button +pointer-buttons+)) button) state)
        (on-pointer-button compositor button state))))

(defun inject-pointer-axis (compositor axis value)
  (srv:send-pointer-axis (compositor-seat compositor) axis value))

(defun client-output (compositor client)
  "The wl_output CLIENT bound, or NIL when it has released it.

A client may release the output -- toytoolkit does, after reading the scale -- and the
id is then free to be reused for anything the client creates next.  Remembering the
resource is not enough: sending `wl_surface.enter' with a released output's id is an
object reference to whatever now holds it, which is how weston-terminal reported
\"invalid object (3), type (wl_shm_pool), message enter(uoff)\" and exited."
  (let ((output (gethash client (compositor-outputs compositor))))
    (cond
      ((null output) nil)
      ((srv:resource-destroyed-p output)
       (remhash client (compositor-outputs compositor))
       nil)
      (t output))))

(defun enter-surface (compositor surface)
  "Tell the client its surface is on the output, once, before the first frame."
  (unless (surface-entered-p surface)
    (let ((output (client-output compositor (srv:resource-client surface))))
      (when output
        (setf (surface-entered-p surface) t)
        (wl-surface.enter surface output)))))

(defun forget-surface (compositor surface)
  "Drop SURFACE's node and any focus it held.

Called when a surface is destroyed or unmapped, from the render loop, because
that is where the scene is walked.  Events are only sent when the client is still
connected: a destroyed surface's client is on its way out, and enter/leave to it
would be a message about an object it no longer has."
  (let ((node (surface-scene-node surface)))
    (when node
      (scene:scene-remove-node node)
      (setf (surface-scene-node surface) nil))
    (let ((seat (compositor-seat compositor)))
      (let ((had-focus (eq surface (srv:seat-keyboard-focus seat))))
        ;; The window leaves the history whether or not it had the keys: an unmapped
        ;; window is not something Alt+Tab may return to (D45).
        (focus-stack-forget compositor surface)
        (when had-focus
          ;; Clear the seat's claim first, without events when the surface is gone
          ;; ("a destroyed surface's client is on its way out"), and then hand the
          ;; keys to the most recently focused window that is still there -- which
          ;; is the whole reason the stack exists.
          (if (srv:resource-destroyed-p surface)
              (setf (srv:seat-keyboard-focus seat) nil)
              (srv:set-keyboard-focus seat nil))
          (let ((next (find-if #'focusable-window-p (compositor-focus-stack compositor))))
            (when next (focus-surface compositor next)))))
      (when (eq surface (srv:seat-pointer-focus seat))
        (if (srv:resource-destroyed-p surface)
            ;; The pointers that pointed here died with the client; dropping the
            ;; seat's claim is all that is left to do.
            (setf (srv:seat-pointer-focus seat) nil)
            (srv:set-pointer-focus seat nil 0 0))))))

(defun prune-surfaces (compositor)
  "Forget surfaces that are gone or no longer mapped, before drawing.

A client that closed its window leaves a destroyed surface behind.  Dropping it
here, not at destroy time, keeps the destroy mid-dispatch from touching a scene
that the render loop is walking; a session must not accumulate tombstones (D26)."
  (dolist (surface (compositor-surfaces compositor))
    (when (or (srv:resource-destroyed-p surface)
              (not (srv:surface-mapped-p surface)))
      (forget-surface compositor surface))))

(defun compositor-device-width (compositor)
  "The target's width in device pixels: the layout width times the output scale."
  (* (compositor-width compositor) (compositor-scale compositor)))

(defun compositor-device-height (compositor)
  "The target's height in device pixels."
  (* (compositor-height compositor) (compositor-scale compositor)))

(defun invalidate-output (compositor)
  "Repaint the whole output on the next frame; returns COMPOSITOR.

The honest escape hatch, and a REPL function in its own right: a mode change, a
scale change, a rearranged stacking order, or a person who suspects the screen is
stale calls it instead of waiting for something to be damaged.  A frame after it
repaints everything, and the frame after that goes back to damage (D48)."
  (setf (compositor-last-items compositor) nil
        (compositor-frame-history-p compositor) nil)
  (mark-dirty compositor)
  compositor)

(defun client-reported-damage (items into)
  "Union into INTO the damage ITEMS carry: what the clients said they painted.

ITEMS is a draw list (SCENE-DRAW-LIST), and this is the *only* honest answer to "what
did the clients repaint" -- the compositor's change region also contains rectangles it
inferred from a node moving or a buffer being swapped, and a backend that mistakes
those for paint has to repaint pixels nobody touched (D66)."
  (render:region-clear into)
  (dolist (item items)
    (dolist (rect (scene:draw-item-damage item))
      (render:region-add-box into rect)))
  into)

(defun frame-damage (compositor items required)
  "The device region this frame has to repaint, or :FULL.

Two answers are merged here.  The *difference* between this frame's draw list and
the last one, plus the damage clients reported since (SCENE-DAMAGE-BETWEEN), says
what changed; REQUIRED -- what a backend with its own buffers says those buffers
can still be trusted to hold -- is the floor under it (D50).  REQUIRED is :FULL,
a region, or NIL for a target that keeps its pixels (headless).

The change is kept on the compositor (COMPOSITOR-FRAME-CHANGE) *before* REQUIRED is
merged into it, because the two are different facts: what changed on the screen is a
property of the frame, and what a buffer has to repaint because it is whole is a
property of that buffer.  A backend that keeps per-buffer damage history records the
former; recording the latter would make every following frame full after a buffer's
first paint (D61)."
  (let ((previous (compositor-last-items compositor)))
    ;; Recorded first, for every path below: the clients' own damage is a fact about
    ;; this frame whatever the compositor then has to repaint because of it.
    (setf (compositor-client-damage compositor)
          (render:region-bounds
           (client-reported-damage
            items
            (or (compositor-client-damage-region compositor)
                (setf (compositor-client-damage-region compositor)
                      (render:make-region))))))
    (cond
      ((not (compositor-frame-history-p compositor))
       (setf (compositor-frame-change compositor) :full)
       :full)
      (t
       (let ((change (or (compositor-frame-change-region compositor)
                         (setf (compositor-frame-change-region compositor)
                               (render:make-region))))
             (damage (or (compositor-damage-region compositor)
                         (setf (compositor-damage-region compositor)
                               (render:make-region)))))
         (render:region-clear change)
         (cond
           ((eq (scene:scene-damage-between previous items change) :full)
            (setf (compositor-frame-change compositor) :full)
            :full)
           (t
            (setf (compositor-frame-change compositor) change)
            (cond
              ((eq required :full) :full)
              (t
               (render:region-copy damage change)
               (when required
                 (render:region-union damage damage required))
               (render:region-intersect-rect
                damage damage 0 0 (compositor-device-width compositor)
                (compositor-device-height compositor))
               damage)))))))))

(defun render-frame (compositor)
  "Draw the scene, present the frame, and fire the callbacks; returns the target.

Returns NIL when there is nothing to draw into (a nested backend whose parent has
not released a buffer yet); the output stays dirty and the backend re-arms the
frame when a buffer comes free.

Frame callbacks fire here, after the draw and the presentation, which is the only
moment the protocol allows (docs/framework.md §3).  Buffers are released after
compositing and before the callbacks, for the clients whose surfaces were mapped
with a buffer (D25).

The presenter runs after the scene is drawn, never before: it attaches and commits
the target, and a target can be shared memory another process is compositing from
(the nested backend's parent).  Committing a target that holds only the background
paint makes every frame arrive blank, and the parent shows a window that is black
or half-drawn depending on when it happens to read -- the flicker the manual test
found (D38).

A frame repaints its damage and nothing else.  A frame with no damage at all draws
nothing and presents nothing -- but still releases buffers and fires callbacks,
because those are answers to clients, not to pixels (D48)."
  (let* ((preparer (compositor-frame-preparer compositor))
         (target nil)
         (required nil))
    (if preparer
        (multiple-value-setq (target required) (funcall preparer compositor))
        (setf target (compositor-target compositor)))
    (unless target
      (return-from render-frame nil))
    (setf (compositor-target compositor) target)
    (let ((scene (compositor-scene compositor)))
      ;; The compositor decides whether this output draws a pointer image; the scene
      ;; draws what it is told.  One flag, projected here rather than duplicated:
      ;; a nested session is a compositor whose pointer is drawn by its parent, and
      ;; it says so with COMPOSITOR-CURSOR-VISIBLE-P (D39).
      (setf (scene:scene-cursor-visible-p scene) (compositor-cursor-visible-p compositor))
      ;; The client's pointer image is not a thing a frame is told about; it is a
      ;; thing a frame asks for (D41).  Before the draw, so the frame that is about
      ;; to be presented already has the right picture.
      (sync-cursor-image compositor)
      (prune-surfaces compositor)
      ;; A popup's place is a function of its parent's place, and its parent may have
      ;; moved since the last frame (a drag, a resize, a cycle).  Asked here, before
      ;; the draw, for the same reason the pointer's image is (D41, D44).
      (sync-popup-positions compositor)
      ;; The tree is final now, so this is the one list both the damage and the
      ;; draw read: they cannot disagree about what the frame contains (D48).
      (let* ((items (scene:scene-draw-list scene))
             (damage (frame-damage compositor items required))
             (full (eq damage :full))
             (empty (and (not full) (render:region-empty-p damage)))
             (drawn '()))
        (let ((draw-start (ffi:monotonic-seconds)))
          (unless empty
            ;; The background is the bottom layer, so it is painted only where no item
            ;; paints over it opaquely: a client's opaque region covers its whole
            ;; window, and filling under it is a write the next composite overwrites
            ;; (D68).
            (let ((background (scene:scene-background-region
                               scene items (unless full damage))))
              (setf (compositor-background-bounds compositor)
                    (render:region-bounds background))
              (unless (render:region-empty-p background)
                (render:target-set-clip target background)
                (render:fill-target target (compositor-background compositor))
                (render:target-clear-clip target))))
          ;; Even an empty frame walks the items: no pixel is touched, but every
          ;; mapped surface comes back in DRAWN, so its buffer is released and its
          ;; frame callback fires.  A client that asks for a frame without damaging
          ;; anything is waiting for exactly that, and a nested backend needs it to
          ;; give back the parent buffer it was holding (D25, D48).
          (setf drawn (scene:scene-render-items scene target :items items
                                                      :damage (unless full damage)))
          (setf (compositor-draw-ms compositor)
                (* 1000 (- (ffi:monotonic-seconds) draw-start))))
        ;; The pixels are in the target now, so this is the first moment at which
        ;; presenting them is truthful.  Presenting first was a real bug, not a
        ;; style choice: see this function's docstring.  An empty frame is still
        ;; announced: the backend decides whether that means anything to present
        ;; (a nested buffer already holding these pixels has nothing to send).
        (let ((presenter (compositor-frame-presenter compositor)))
          (when presenter
            (funcall presenter compositor target (if full :full damage))))
        (dolist (surface drawn)
          (enter-surface compositor surface)
          ;; The pixels are in the target now, so the client may have its buffer
          ;; back -- before the frame callback, so a client that redraws on the
          ;; callback already knows which buffer is free.  A double-buffered client
          ;; deadlocks without this (D25).
          (srv:release-surface-buffer surface)
          (srv:surface-presented surface))
        ;; The damage has been paid; the next frame starts from this one's list.
        (setf (compositor-frame-history-p compositor) t
              (compositor-last-items compositor) items)
        (scene:scene-consume-damage items)
        (unless full
          (incf (compositor-partial-frame-count compositor)))
        (setf (compositor-last-damage compositor)
              (if full :full (render:region-bounds damage))))
      (incf (compositor-frame-count compositor))
      (setf (compositor-dirty-p compositor) nil)
      (setf (compositor-surfaces compositor)
            (remove-if #'srv:resource-destroyed-p (compositor-surfaces compositor)))
      target)))

(defun reclamp-windows (compositor)
  "Keep every window inside the output after the output changed size; returns how many moved.

D37's open question: a parent configure that shrinks a nested session used to leave its
windows where they were, half of them outside the new output and unreachable.  The rule
is the same one CLAMP-TO-OUTPUT applies to a drag (D43) -- a window that fits stays
fully inside, a window larger than the output covers it -- so this is the same helper
the move grab uses, applied to every window at once.  Popups are not moved here: their
node follows its parent on the next frame (D44), which is where their placement lives."
  (let ((moved 0))
    (dolist (surface (compositor-surfaces compositor))
      (when (and (srv:surface-mapped-p surface) (window-surface-p surface))
        (let ((node (surface-scene-node surface)))
          (when node
            (multiple-value-bind (old-x old-y) (scene:node-position node)
              (grab:clamp-node-to-output node
                                         (compositor-width compositor)
                                         (compositor-height compositor))
              (multiple-value-bind (new-x new-y) (scene:node-position node)
                (unless (and (= old-x new-x) (= old-y new-y))
                  (incf moved)
                  (srv:log-message :debug "window ~D re-clamped from (~D, ~D) to (~D, ~D)"
                                   (srv:resource-id surface) old-x old-y new-x new-y))))))))
    moved))

(defun resize-compositor (compositor width height)
  "Make COMPOSITOR a WIDTH x HEIGHT output; returns it.

The scene and the compositor's own memory target are rebuilt, because both are sized
by the output.  A backend with a frame preparer keeps its own destination -- the
nested backend's is the parent's shm buffer, which that backend rebuilds itself -- so
only the parts the framework owns change here."
  (unless (and (= width (compositor-width compositor))
               (= height (compositor-height compositor)))
    (setf (compositor-width compositor) width
          (compositor-height compositor) height
          (scene:scene-width (compositor-scene compositor)) width
          (scene:scene-height (compositor-scene compositor)) height)
    (unless (compositor-frame-preparer compositor)
      (render:destroy-target (compositor-target compositor))
      (setf (compositor-target compositor)
            (render:make-target (* width (compositor-scale compositor))
                                (* height (compositor-scale compositor))))
      (render:fill-target (compositor-target compositor)
                          (compositor-background compositor)))
    ;; The windows are the size they are; the output is not.  Anything that no longer
    ;; fits is brought back inside (D46).
    (reclamp-windows compositor)
    ;; The target is new (headless) or the parent's buffer is (nested), so nothing
    ;; it holds can be trusted: this is a full repaint (D48).
    (setf (compositor-last-items compositor) nil
          (compositor-frame-history-p compositor) nil)
    (setf (compositor-dirty-p compositor) t))
  compositor)

(defun write-frame-png (compositor path)
  "Write the current target to PATH as a PNG: the screenshot, and the gate's artefact.

The image is the target's own size, so a scale-2 output writes 2x the layout size:
a screenshot of what a screen would show, not of the coordinate space behind it."
  (let ((target (compositor-target compositor)))
    (png:write-png path (render:target-octets-copy target)
                   (render:target-width target)
                   (render:target-height target))))

(defun frame-pixel (compositor x y)
  "The premultiplied 0xAARRGGBB pixel at layout (X, Y) of the current target.

X and Y are output-local *layout* coordinates, which is the space every policy and
every test speaks; on a scale-2 output the pixel read is that coordinate's
top-left device pixel.  A caller that wants a device pixel calls
FRAME-PIXEL-DEVICE."
  (render::target-pixel (compositor-target compositor)
                        (* x (compositor-scale compositor))
                        (* y (compositor-scale compositor))))

(defun frame-octets (compositor)
  "A copy of the current target's pixels (BGRA octets): a screenshot, or evidence.

Copied out of the mapping, so a caller may keep it while the next frame is drawn --
which is how a gate compares an incremental frame with a full one."
  (render:target-octets-copy (compositor-target compositor)))

(defun frame-pixel-device (compositor x y)
  "The premultiplied 0xAARRGGBB pixel at device (X, Y) of the current target."
  (render::target-pixel (compositor-target compositor) x y))

(defun output-damage-bounds (compositor)
  "What the last frame repainted: :FULL, or (X Y WIDTH HEIGHT) of the damage."
  (compositor-last-damage compositor))

;;; ---------------------------------------------------------------------------
;;; Popups: placement, the grab, and the way back
;;;
;;; The protocol layer (wayland.server) owns the popup state machine; what is left
;;; for a compositor is the three things it alone can know: where the output is so
;;; the position can be constrained, what the pointer does while a popup holds an
;;; explicit grab, and what to do when the popup goes away (D44).
;;; ---------------------------------------------------------------------------

(defun popup-compositor (surface)
  "The compositor a wl_surface's popup belongs to, or NIL."
  (let ((owner (and surface (srv:surface-owner surface))))
    (and owner (cf-compositor-headless owner))))

(defmethod srv:popup-constraint-box ((surface cf-surface) popup)
  "The output, expressed in POPUP's parent's window-geometry space.

The configure's (x, y) is relative to the upper-left corner of the parent's window
geometry, so the output's bounds are that same origin taken *negative*: a parent
whose geometry starts at (32, 32) of a 1280x800 output constrains its popups to the
box (-32 -32 1280 800)."
  (let ((compositor (popup-compositor surface)))
    (when compositor
      (multiple-value-bind (parent-x parent-y) (popup-parent-geometry popup)
        (when parent-x
          (list (- parent-x) (- parent-y)
                (compositor-width compositor) (compositor-height compositor)))))))

(defmethod srv:popup-grab-requested ((surface cf-surface) popup seat serial)
  "A validated xdg_popup.grab: the popup owns the pointer until it is dismissed."
  (declare (ignore seat serial))
  (let ((compositor (popup-compositor surface)))
    (when compositor
      (start-grab compositor (grab:begin-popup-grab popup))
      (srv:log-message :debug "popup ~D: explicit grab" (srv:resource-id popup))
      t)))

(defmethod srv:popup-dismissed ((surface cf-surface) popup reason)
  "POPUP is off the screen: end its grab, and give the keyboard back to its parent.

The node is not removed here.  The surface is already unmapped, so PRUNE-SURFACES
drops the node on the next frame -- and doing it here would remove a node from a
scene the render loop may be walking (the same rule as D26's tombstones)."
  (declare (ignore reason))
  (let ((compositor (popup-compositor surface)))
    (when compositor
      (let ((grab (compositor-grab compositor)))
        ;; A grab that swallowed the press that dismissed it stays until that
        ;; button's release has been swallowed too: ending it here would deliver
        ;; the release to a client that never saw the press (GRAB-BUTTON does it).
        (when (and (typep grab 'grab:popup-grab)
                   (eq popup (grab:popup-grab-popup grab))
                   (null (grab:popup-grab-swallowed grab)))
          (grab:grab-end grab :reason :popup-dismissed)))
      ;; Keyboard focus goes back to the window the menu belonged to; a menu that
      ;; kept the keys after closing would type into nothing.
      (when (eq surface (srv:seat-keyboard-focus (compositor-seat compositor)))
        (let* ((parent-shell (srv:xdg-popup-parent popup))
               (parent-surface (and parent-shell (srv:xdg-surface-surface parent-shell))))
          (focus-surface compositor parent-surface))))
    nil))

(defun popup-keeps-pointer-p (compositor popup x y)
  "Does a press at (X, Y) belong to POPUP's stack -- the popup or one of its siblings?

A press inside any popup of the same toplevel keeps the stack open: submenus are
popups of their own, and clicking a submenu must not read as a click outside the menu
it belongs to."
  (multiple-value-bind (node local-x local-y)
      (scene:scene-hit-test (compositor-scene compositor) x y)
    (declare (ignore local-x local-y))
    (let* ((surface (and node (typep node 'scene:buffer-node)
                              (scene:buffer-node-surface node)))
           (shell (and surface (srv:surface-shell-surface surface)))
           (role (and shell (srv:xdg-surface-role shell))))
      (and (typep role 'srv:xdg-popup)
           (eq (srv:xdg-popup-toplevel role) (srv:xdg-popup-toplevel popup))))))

(defmethod grab:grab-motion ((grab grab:popup-grab) x y)
  "A popup grab is an owner-events grab: the pointer is delivered as usual.

What the grab changes is who *ends* the interaction, not who hears it -- so motion
and hover behave exactly as they would with no grab at all."
  (declare (ignore x y))
  (let ((compositor (grab:grab-owner grab)))
    (when compositor (update-pointer compositor))))

(defmethod grab:grab-button ((grab grab:popup-grab) button state)
  "Inside the stack the client hears the press; outside, the popup is dismissed.

The press that dismisses is swallowed, and so is its release: it was a click on
\"away\", not a click on whatever is under the pointer, and a client that acts on it
would be acting on a menu that had already closed."
  (let* ((compositor (grab:grab-owner grab))
         (popup (grab:popup-grab-popup grab)))
    (cond
      ((eq state :pressed)
       (if (popup-keeps-pointer-p compositor popup
                                  (compositor-cursor-x compositor)
                                  (compositor-cursor-y compositor))
           (progn (on-pointer-button compositor button state) t)
           (progn
             (pushnew button (grab:popup-grab-swallowed grab))
             (srv:dismiss-popup-chain popup :reason :click-outside)
             t)))
      ((member button (grab:popup-grab-swallowed grab))
       (setf (grab:popup-grab-swallowed grab)
             (remove button (grab:popup-grab-swallowed grab)))
       ;; The dismissal's own release is the last thing this grab has to do.
       (when (null (grab:popup-grab-swallowed grab))
         (grab:grab-end grab :reason :dismissed))
       t)
      (t (on-pointer-button compositor button state) t))))

(defmethod grab:grab-key ((grab grab:popup-grab) key-name state)
  "Plain Escape dismisses the stack -- the keyboard half of `or using the keyboard'.

Alt+Escape is deliberately *not* consumed: it is the compositor's quit binding, and a
menu that swallowed the way out of the session would be a trap.  Any other key falls
through too, so the bindings and the focused client see what they would without the
grab."
  (let ((compositor (grab:grab-owner grab)))
    (when (and (eq state :pressed)
               (string-equal key-name "Escape")
               (not (and compositor
                         (logtest input:+modifier-mod1+
                                  (input:modifiers-depressed
                                   (compositor-modifiers compositor))))))
      (srv:dismiss-popup-chain (grab:popup-grab-popup grab) :reason :keyboard)
      t)))

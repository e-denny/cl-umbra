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
   (scene-node :initform nil :accessor surface-scene-node))
  (:documentation "A server surface with the framework's own state on top (D7)."))

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
   (width :initarg :width :reader compositor-width)
   (height :initarg :height :reader compositor-height)
   (background :initarg :background :initform #xFF000000 :reader compositor-background)
   (target :initarg :target :reader compositor-target)
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

(defun send-output-events (output width height)
  "The initial events of the headless output, done last (docs/protocol-layer.md §8)."
  (wl-output.geometry output 0 0 0 0 0 "cl-umbra" "headless" 0)
  (wl-output.mode output 1 width height 60000)
  (wl-output.scale output 1)
  (wl-output.name output "HEADLESS-1")
  (wl-output.description output "cl-compositor-framework headless output")
  (wl-output.done output))

(defun make-headless-compositor (&key (width 256) (height 256)
                                      (display-name (uiop:getenv "WAYLAND_DISPLAY"))
                                      (runtime-dir (uiop:getenv "XDG_RUNTIME_DIR"))
                                      (background #xFF000000)
                                      (reactor nil))
  "A display offering wl_compositor, wl_shm, wl_output and xdg_wm_base, rendering
into memory.

Returns the compositor; the display is `(compositor-display ...)`, and
`(render-frame ...)` draws the current state."
  (let* ((display (srv:make-display :display-name display-name
                                               :runtime-dir runtime-dir
                                               :reactor (or reactor
                                                             (wayland.reactor:make-reactor))))
         (seat (srv:make-seat display
                              :name "seat0"
                              :capabilities (logior srv:+wl-seat-capability-pointer+
                                                    srv:+wl-seat-capability-keyboard+)))
         (compositor (make-instance 'headless-compositor
                                    :display display
                                    :width width
                                    :height height
                                    :background background
                                    :seat seat
                                    :scene (scene:make-scene width height)
                                    :target (render:make-target width height))))
    ;; wl_compositor version 3: weston's window.c clients bind 3 unconditionally
    ;; (they were the reason this was not v1), so v3 is the lowest honest version
    ;; that lets a real pointer-using client connect.  v3 adds one request,
    ;; set_buffer_scale, which this server accepts and validates but draws at 1:1
    ;; until the renderer scales (2b); the output advertises scale 1, so a
    ;; well-behaved client never asks for more.  v4 would promise damage_buffer.
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
                                       (send-output-events resource width height)))
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

(defun ensure-scene-node (compositor surface)
  "The node SURFACE is drawn through, creating it on the first mapped commit.

A surface with a shell role is placed by ON-NEW-TOPLEVEL.  A bare wl_surface has
no role and no compositor policy about where it goes, so its node stays at the
scene origin and its attach offset -- the client's own statement about its
content -- puts its pixels where the client asked.  That is exactly what phase 2a
did, and the shm gate still checks it pixel by pixel."
  (let ((node (surface-scene-node surface)))
    (unless node
      (setf node (if (srv:surface-shell-surface surface)
                     (on-new-toplevel compositor surface)
                     (scene:scene-add-node (compositor-scene compositor)
                                           (scene:make-buffer-node surface)))))
    ;; Committing is not raising.  Phase 2a used commit order as draw order, which
    ;; made two redrawing clients flip places several times a second; stacking is
    ;; the compositor's decision, and v0's decision is "the order windows were
    ;; placed in".  SCENE:NODE-RAISED is the call a click-to-raise policy makes.
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

;;; ---------------------------------------------------------------------------
;;; Commit: what a compositor does about it
;;; ---------------------------------------------------------------------------

(defmethod srv:surface-committed ((surface cf-surface) damage)
  "Mark the output dirty and arrange one render at the end of this cycle.

The damage list is ignored for now -- v0 repaints the whole target, and damage
tracking is 2b's job (docs/memory-and-rendering.md §7)."
  (declare (ignore damage))
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
        ((null surface)
         (when (srv:seat-pointer-focus seat)
           (srv:set-pointer-focus seat nil 0 0)))
        ((eq surface (srv:seat-pointer-focus seat))
         (srv:send-pointer-motion seat x y))
        (t
         (srv:set-pointer-focus seat surface x y))))))

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
    (multiple-value-bind (under x y) (surface-under-cursor compositor)
      (cond ((null surface)
             (srv:set-pointer-focus seat nil 0 0))
            ((eq under surface)
             (srv:set-pointer-focus seat surface x y))))
    surface))

(defmethod srv:seat-focus-changed ((seat srv:seat) surface has-focus)
  "Tell an xdg_toplevel it is activated or not.

The state array is recomputed on every configure, never patched, so a losing
toplevel gets an empty array rather than a stale `activated`."
  (let ((shell (and surface (srv:surface-shell-surface surface))))
    (when (and shell (srv:xdg-surface-role shell))
      (srv:set-toplevel-activated (srv:xdg-surface-role shell) has-focus)))
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

(defun cycle-views (compositor)
  "Bring the bottom window to the top and give it the keyboard (tinywl's Alt+F1).

"Bottom" is draw order, so cycling visits every window once and the old one ends
up at the back -- the same rule tinywl's view list has."
  (let* ((root (scene:scene-root (compositor-scene compositor)))
         (windows (remove-if-not (lambda (node) (typep node 'scene:buffer-node))
                                 (scene:node-children root))))
    (when windows
      (let ((node (first windows)))
        (scene:node-raised node)
        (focus-surface compositor (scene:buffer-node-surface node))
        (mark-dirty compositor)
        node))))

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
  "Ask the client for a new size: for a shm client, that is what resizing is."
  (let* ((surface (scene:buffer-node-surface (grab:grab-node grab)))
         (shell (and surface (srv:surface-shell-surface surface)))
         (toplevel (and shell (srv:xdg-surface-role shell))))
    (when toplevel
      (srv:request-toplevel-size toplevel width height))))

(defun handle-key (compositor name state)
  "Press or release the key called NAME (:pressed or :released).

The modifier mask is updated from the keymap's own table first, so a binding sees
the mask the press produced; then a grab may take the key, then a binding, and
only then the focused client."
  (let* ((seat (compositor-seat compositor))
         (modifiers (compositor-modifiers compositor))
         (pressed-p (eq state :pressed))
         (grab (compositor-grab compositor)))
    (input:update-modifiers modifiers name pressed-p)
    (cond
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

(defun inject-pointer-motion (compositor x y)
  "Move the pointer to (X, Y) in output space and let the scene decide who hears it.

While a grab holds the pointer the grab decides: the client under the pointer is
not sent motion events for a drag it is not doing."
  (scene:set-node-position (scene:scene-cursor (compositor-scene compositor)) x y)
  (let ((grab (compositor-grab compositor)))
    (if grab
        (grab:grab-motion grab x y)
        (update-pointer compositor)))
  ;; The cursor moved, so the frame changed even if no client did anything.
  (mark-dirty compositor))

(defparameter +pointer-buttons+
  '((:left . #x110) (:right . #x111) (:middle . #x112)))

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

(defun dragged-button (compositor &optional (default #x110))
  (or (first (srv:seat-pressed-buttons (compositor-seat compositor))) default))

(defmethod srv:toplevel-move-requested ((surface cf-surface) toplevel serial seat)
  "A validated xdg_toplevel.move: start an interactive move of this window."
  (declare (ignore seat))
  (let* ((compositor (cf-compositor-headless (srv:surface-owner surface)))
         (node (surface-scene-node surface)))
    (cond
      ((null node)
       (srv:log-message :debug "toplevel ~D asked to move but has no scene node"
                        (srv:resource-id toplevel))
       nil)
      (t
       (start-grab compositor
                   (grab:begin-move-grab node
                                         (compositor-cursor-x compositor)
                                         (compositor-cursor-y compositor)
                                         :button (dragged-button compositor)))
       (srv:log-message :debug "toplevel ~D: interactive move (serial ~D)"
                        (srv:resource-id toplevel) serial)
       t))))

(defmethod srv:toplevel-resize-requested ((surface cf-surface) toplevel serial seat edges)
  "A validated xdg_toplevel.resize: start an interactive resize from EDGES."
  (declare (ignore seat))
  (let* ((compositor (cf-compositor-headless (srv:surface-owner surface)))
         (node (surface-scene-node surface)))
    (cond
      ((null node)
       (srv:log-message :debug "toplevel ~D asked to resize but has no scene node"
                        (srv:resource-id toplevel))
       nil)
      (t
       (start-grab compositor
                   (grab:begin-resize-grab node
                                           (compositor-cursor-x compositor)
                                           (compositor-cursor-y compositor)
                                           edges
                                           :button (dragged-button compositor)
                                           :min-width (max 1 (srv:xdg-toplevel-min-width toplevel))
                                           :min-height (max 1 (srv:xdg-toplevel-min-height toplevel))))
       (srv:log-message :debug "toplevel ~D: interactive resize (serial ~D, edges ~D)"
                        (srv:resource-id toplevel) serial edges)
       t))))

(defun inject-pointer-button (compositor button state)
  "SYNTHETIC pointer button (:left, :right, :middle), pressed or released.

A press is also the click that focuses: the window under the pointer takes the
keyboard, which is what makes clicking another window work at all (D32).  A press
on the bare output changes nothing -- there is no click-to-raise or
click-to-dismiss policy in v0."
  (let* ((seat (compositor-seat compositor))
         (code (or (cdr (assoc button +pointer-buttons+)) button))
         (grab (compositor-grab compositor)))
    (cond
      ;; A grab owns the pointer: the grab decides, and the event is not also
      ;; delivered as a click to the client under it.
      (grab
       (grab:grab-button grab code state))
      (t
       (when (eq state :pressed)
         (multiple-value-bind (surface x y) (surface-under-cursor compositor)
           (when surface
             (unless (eq surface (srv:seat-pointer-focus seat))
               (srv:set-pointer-focus seat surface x y))
             (unless (eq surface (srv:seat-keyboard-focus seat))
               (focus-surface compositor surface)))))
       (srv:send-pointer-button seat code state)))))

(defun inject-pointer-axis (compositor axis value)
  (srv:send-pointer-axis (compositor-seat compositor) axis value))

(defun enter-surface (compositor surface)
  "Tell the client its surface is on the output, once, before the first frame."
  (unless (surface-entered-p surface)
    (let ((output (gethash (srv:resource-client surface)
                           (compositor-outputs compositor))))
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
      (when (eq surface (srv:seat-keyboard-focus seat))
        (if (srv:resource-destroyed-p surface)
            (setf (srv:seat-keyboard-focus seat) nil)
            (srv:set-keyboard-focus seat nil)))
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

(defun render-frame (compositor)
  "Draw the scene, cursor last, and present the frame; returns the target.

Frame callbacks fire here, after the draw, which is the only moment the protocol
allows (docs/framework.md §3).  Buffers are released after compositing and before
the callbacks, for the clients whose surfaces were actually drawn (D25)."
  (let* ((target (compositor-target compositor))
         (scene (compositor-scene compositor)))
    (render:fill-target target (compositor-background compositor))
    (prune-surfaces compositor)
    (dolist (surface (scene:scene-render scene target))
      (enter-surface compositor surface)
      ;; The pixels are in the target now, so the client may have its buffer
      ;; back -- before the frame callback, so a client that redraws on the
      ;; callback already knows which buffer is free.  A double-buffered client
      ;; deadlocks without this (D25).
      (srv:release-surface-buffer surface)
      (srv:surface-presented surface))
    (incf (compositor-frame-count compositor))
    (setf (compositor-dirty-p compositor) nil)
    (setf (compositor-surfaces compositor)
          (remove-if #'srv:resource-destroyed-p (compositor-surfaces compositor)))
    target))

(defun write-frame-png (compositor path)
  "Write the current target to PATH as a PNG: the screenshot, and the gate's artefact."
  (let ((target (compositor-target compositor)))
    (png:write-png path (render::target-octets target)
                   (compositor-width compositor)
                   (compositor-height compositor))))

(defun frame-pixel (compositor x y)
  "The premultiplied 0xAARRGGBB pixel at X, Y of the current target."
  (render::target-pixel (compositor-target compositor) x y))

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
  ((entered-p :initform nil :accessor surface-entered-p))
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
    (render:fill-target (compositor-target compositor) background)
    compositor))

;;; ---------------------------------------------------------------------------
;;; Commit: what a compositor does about it
;;; ---------------------------------------------------------------------------

(defmethod srv:surface-committed ((surface cf-surface) damage)
  "Mark the output dirty and arrange one render at the end of this cycle.

The damage list is ignored for now -- phase 2a repaints the whole target, and
damage tracking is the next slice's job (docs/memory-and-rendering.md §7)."
  (declare (ignore damage))
  (let* ((compositor (cf-compositor-headless (srv:surface-owner surface))))
    (unless (member surface (compositor-surfaces compositor))
      ;; Keep commit order: a surface committed again moves to the front, which is
      ;; what a client raising its own window through a commit expects.
      (setf (compositor-surfaces compositor)
            (append (compositor-surfaces compositor) (list surface))))
    (setf (compositor-dirty-p compositor) t)
    ;; tinywl's policy, and the only one that can exist without a scene graph:
    ;; a window that *maps* takes focus, so the client learns it is activated and
    ;; the keys it asked for arrive (D27).
    ;;
    ;; Only on the transition, not on every commit: focus-surface sends
    ;; enter/leave and re-places the pointer at (0,0), so calling it per commit
    ;; teleports the cursor and sprays enter events at the client (found by the
    ;; seat gate: the pointer position was back at 0,0 after its buttons).
    (when (and (srv:surface-mapped-p surface)
               (srv:surface-shell-surface surface)
               (not (eq surface (srv:seat-keyboard-focus (compositor-seat compositor)))))
      (focus-surface compositor surface))
    ;; One render per cycle, however many commits arrived in it.  Frame callbacks
    ;; are queued *by* the render, after SERVICE-CLIENT has already flushed this
    ;; client, so the flush has to happen here: an event nobody writes is an event
    ;; the client waits for forever.
    (reactor:add-idle
     (srv:display-reactor (compositor-display compositor))
     (lambda ()
       (when (compositor-dirty-p compositor)
         (render-frame compositor)
         (srv:flush-all (compositor-display compositor)))))
    surface))

;;; ---------------------------------------------------------------------------
;;; Presenting
;;; ---------------------------------------------------------------------------

;;; ---------------------------------------------------------------------------
;;; Focus and synthetic input
;;; ---------------------------------------------------------------------------
;;
;; There is no libinput here and no cursor image: a *backend* reports what a device
;; did, and a compositor decides who hears it.  These functions are that seam, and
;; they are also how the gate drives real clients, which is why they are exported
;; rather than kept behind a test-only door.

(defun focus-surface (compositor surface)
  "Give keyboard and pointer focus to SURFACE; NIL clears both.

One call, because enter/leave, the pointer's position and the toplevel's activated
configure must not drift apart (docs/framework.md §5)."
  (let ((seat (compositor-seat compositor)))
    (srv:set-keyboard-focus seat surface)
    (srv:set-pointer-focus seat surface 0 0)
    surface))

(defmethod srv:seat-focus-changed ((seat srv:seat) surface has-focus)
  "Tell an xdg_toplevel it is activated or not.

The state array is recomputed on every configure, never patched, so a losing
toplevel gets an empty array rather than a stale `activated`."
  (let ((shell (and surface (srv:surface-shell-surface surface))))
    (when (and shell (srv:xdg-surface-role shell))
      (srv:set-toplevel-activated (srv:xdg-surface-role shell) has-focus)))
  nil)

(defun inject-key (compositor name state)
  "Press or release the key called NAME (:pressed or :released).

The modifier mask is updated from the keymap's own table, so what the client
computes and what we advertise agree by construction."
  (let* ((seat (compositor-seat compositor))
         (modifiers (compositor-modifiers compositor))
         (pressed-p (eq state :pressed)))
    (input:update-modifiers modifiers name pressed-p)
    (srv:send-key-event seat (input:keycode name) state
                        :mods-depressed (input:modifiers-depressed modifiers)
                        :mods-latched (input:modifiers-latched modifiers)
                        :mods-locked (input:modifiers-locked modifiers)
                        :group (input:modifiers-group modifiers))))

(defun inject-pointer-motion (compositor x y)
  (srv:send-pointer-motion (compositor-seat compositor) x y))

(defparameter +pointer-buttons+
  '((:left . #x110) (:right . #x111) (:middle . #x112)))

(defun inject-pointer-button (compositor button state)
  "SYNTHETIC pointer button (:left, :right, :middle), pressed or released."
  (let ((code (or (cdr (assoc button +pointer-buttons+)) button)))
    (srv:send-pointer-button (compositor-seat compositor) code state)))

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

(defun render-frame (compositor)
  "Draw every mapped surface and present the frame; returns the target.

Frame callbacks fire here, after the draw, which is the only moment the protocol
allows (docs/framework.md §3)."
  (let ((target (compositor-target compositor)))
    (render:fill-target target (compositor-background compositor))
    (dolist (surface (compositor-surfaces compositor))
      (when (render:render-surface target surface)
        (enter-surface compositor surface)
        ;; The pixels are in the target now, so the client may have its buffer
        ;; back -- before the frame callback, so a client that redraws on the
        ;; callback already knows which buffer is free.  A double-buffered client
        ;; deadlocks without this (D25).
        (srv:release-surface-buffer surface)
        (srv:surface-presented surface)))
    (incf (compositor-frame-count compositor))
    (setf (compositor-dirty-p compositor) nil)
    ;; A client that closed its window leaves a destroyed surface behind.  Drop it
    ;; here, not at destroy time: the destroy happens mid-dispatch, while this
    ;; list is being walked by nobody -- but the list is also the draw order, and
    ;; a session must not accumulate tombstones (D26).
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

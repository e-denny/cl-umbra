;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The card a seat hands out: a DRM output that lives through a VT switch (4d-3).
;;;;
;;;; The first three slices of phase 4 each proved one half of the same sentence: the
;;;; card can be taken from a free machine (D54), it can be taken back and given back
;;;; (D55), and a session can be told when it is allowed to (D56).  None of them
;;;; joined them, because the join is only interesting on a machine where somebody
;;;; else owns the screen -- and that is what this module is.
;;;;
;;;; The shape of the join is forced by the seat's contract:
;;;;
;;;;   * the compositor may not open /dev/dri/cardN, because while a seat owns the
;;;;     session the descriptor is the only handle that outlives a VT switch, and the
;;;;     second opener is not the one that keeps master (D56 §4, D55's EACCES);
;;;;   * the descriptor is therefore opened through the seat, and closed through the
;;;;     seat: the seat closes what the seat opened, and a second close(2) on a
;;;;     number that has since been reused is somebody else's descriptor (this
;;;;     module's one rule that is not obvious);
;;;;   * enabling and disabling are callbacks, not calls, so the output registers
;;;;     itself with the session and survives every switch without the compositor
;;;;     touching it.
;;;;
;;;; What it does not do: no reactor source and no frame loop.  A compositor asks for
;;;; a target, draws, presents, and the seat does the rest.

(in-package #:cf.backend.vt)

;;; ---------------------------------------------------------------------------
;;; The output
;;; ---------------------------------------------------------------------------

(defclass vt-output ()
  ((session :initarg :session :reader vt-output-session)
   (path :initarg :path :reader vt-output-path)
   ;; What was programmed, remembered across a switch so a re-enable puts back the
   ;; same screen rather than whatever the card happens to prefer now (D55).
   (connector-name :initarg :connector :initform nil :accessor vt-output-connector-name)
   (crtc-id :initarg :crtc-id :initform nil :accessor vt-output-crtc-id)
   (mode :initarg :mode :initform nil :accessor vt-output-mode)
   (buffer-count :initarg :buffer-count :initform 2 :reader vt-output-buffer-count)
   ;; What is held while the seat is enabled.
   (device :initarg :device :initform nil :accessor vt-output-device)
   (device-id :initarg :device-id :initform nil :accessor vt-output-device-id)
   (scanout :initform nil :accessor vt-output-scanout)
   ;; One render target per scanout buffer, made on first use and kept until the
   ;; output is disabled: a target borrows a buffer's mapping, so making one per
   ;; frame would be a pixman image per frame for nothing.
   (targets :initform (make-hash-table :test #'eq) :reader vt-output-targets)
   ;; Frames, and what each of the two buffers may still be trusted to hold.  With
   ;; two buffers a buffer is at most two frames behind, so a buffer's age is the
   ;; number of frames it missed and the history needs those and no more (D50, D61).
   ;; SEQUENCE counts frames prepared, whether or not they reached the card -- a
   ;; frame that painted nothing still happened, and the history has to be able to
   ;; say so.  BUFFER-FRAMES is which frame's pixels each buffer holds, so "what did
   ;; this buffer miss?" is a subtraction.  DAMAGE-HISTORY is the change of the last
   ;; two frames, newest first; HISTORY-REGIONS is the pair it reuses, so recording
   ;; a frame allocates nothing.
   (sequence :initform 0 :accessor vt-output-frame-sequence)
   (current-frame :initform nil :accessor vt-output-current-frame)
   (buffer-frames :initform (make-hash-table :test #'eq)
                  :reader vt-output-buffer-frames)
   (buffer-repaints :initform (make-hash-table :test #'eq)
                    :reader vt-output-buffer-repaints)
   (damage-history :initform nil :accessor vt-output-damage-history)
   (history-regions :initform nil :accessor vt-output-history-regions)
   (width :initform 0 :accessor vt-output-width)
   (height :initform 0 :accessor vt-output-height)
   ;; The hooks, kept so CLOSE-VT-OUTPUT can remove the two it added.
   (enable-hook :initform nil :accessor vt-output-enable-hook)
   (disable-hook :initform nil :accessor vt-output-disable-hook)
   (enables :initform 0 :accessor vt-output-enable-count)
   (disables :initform 0 :accessor vt-output-disable-count))
  (:documentation
   "One screen, on a card the seat opens, that comes back by itself.

ENABLED-P is DRM-SCANOUT-SCANOUT not being NIL: there is no third state in which
the output is half on.  The two counts are evidence -- a VT switch increments the
disable count and then the enable count, and a compositor's log can say how many
switches it survived (the phase-4 soak asks for an eight-hour one).

The session outlives the output and not the other way round, which is why this is
not a subclass of anything and why closing it removes its hooks."))

(defun vt-output-enabled-p (output)
  (and (vt-output-scanout output) t))

;;; ---------------------------------------------------------------------------
;;; A descriptor into a card
;;; ---------------------------------------------------------------------------
;;
;; The one call that needs a real seat and a real card, as a generic, for the same
;; reason cf.session's eight are generics: the tests below drive the whole enable and
;; disable machine with a recording session and a card with no kernel behind it.

(defgeneric open-vt-device (output session path)
  (:documentation
   "Open PATH through SESSION for OUTPUT; returns (values DEVICE DEVICE-ID).

The default is the honest one: the seat opens the descriptor, DRM-OPEN-DEVICE-FROM-
FD adopts it without opening the path, and a failure puts the descriptor back to the
seat rather than leaving the seat believing a device is open that is not."))

(defmethod open-vt-device ((output vt-output) session path)
  (multiple-value-bind (fd id) (session:open-session-device session path)
    (handler-case
        (values (drm:open-drm-device-from-fd fd :path path) id)
      (error (condition)
        ;; DRM-OPEN-DEVICE-FROM-FD has already closed the descriptor it was handed;
        ;; what is left is to tell the seat, whose bookkeeping still has it open.
        (ignore-errors (session:close-session-device session id))
        (error condition)))))

(defun close-vt-device (output)
  "Give OUTPUT's descriptor back to the seat, and forget the device.

The seat closes what the seat opened.  When the seat is already disabled it has
closed the device itself -- a disable revokes every descriptor it handed out -- so
this only drops the device's claim to the number: a second close(2) on a number the
kernel has since reused would close somebody else's file.  That distinction is why
the slot is cleared by hand rather than by CLOSE-DRM-DEVICE."
  (let ((device (vt-output-device output))
        (id (vt-output-device-id output))
        (session (vt-output-session output)))
    (setf (vt-output-device output) nil
          (vt-output-device-id output) nil)
    (when (and id session (session:session-enabled-p session))
      (ignore-errors (session:close-session-device session id)))
    (when device
      (setf (drm:drm-device-fd device) nil)
      (drm:close-drm-device device))
    (values)))

;;; ---------------------------------------------------------------------------
;;; Enable and disable: the two things a VT switch does to a compositor
;;; ---------------------------------------------------------------------------

(defun enable-vt-output (output)
  "Take the card through the seat and program the screen.  Idempotent.

Doing this twice is not an error -- an enable callback that arrives after the
compositor already enabled by hand is the seat being correct, not the compositor
being wrong -- so an enabled output returns itself.

A failure anywhere after the descriptor arrived puts the descriptor back and
re-signals: the screen is not half taken, and the seat is not asked to close what
the compositor still holds."
  (when (vt-output-enabled-p output)
    (return-from enable-vt-output output))
  (let ((session (vt-output-session output)))
    ;; A device handed to OPEN-VT-OUTPUT is used as it is.  That is not a
    ;; convenience: on a VT the seat grants DRM master to one descriptor per
    ;; activation, so opening the card a second time to *check* it takes master away
    ;; from the descriptor that wants it (measured: a probe's descriptor was master
    ;; and the output's was refused EACCES a moment later).
    (multiple-value-bind (device id)
        (if (vt-output-device output)
            (values (vt-output-device output) (vt-output-device-id output))
            (open-vt-device output session (vt-output-path output)))
      (setf (vt-output-device output) device
            (vt-output-device-id output) id)
      (handler-case
          (let ((scanout (drm:drm-open-scanout
                          device
                          :connector (vt-output-connector-name output)
                          :crtc-id (vt-output-crtc-id output)
                          :mode (vt-output-mode output)
                          :buffer-count (vt-output-buffer-count output))))
            (setf (vt-output-scanout output) scanout
                  (vt-output-connector-name output)
                  (drm:drm-connector-name (drm:drm-scanout-connector scanout))
                  (vt-output-crtc-id output) (drm:drm-scanout-crtc-id scanout)
                  (vt-output-mode output) (drm:drm-scanout-mode scanout)
                  (vt-output-width output) (drm:drm-scanout-width scanout)
                  (vt-output-height output) (drm:drm-scanout-height scanout))
            (incf (vt-output-enable-count output))
            output)
        (error (condition)
          (close-vt-device output)
          (error condition))))))

(defun forget-vt-frame-history (output)
  "Forget every buffer and every recorded frame; returns nothing.

A disable destroys the scanout's buffers, so their frame numbers name memory that
no longer exists: a re-enable gets fresh buffers, and a fresh buffer is one nobody
has painted, which is :FULL and not a stale claim about pixels."
  (clrhash (vt-output-buffer-frames output))
  (clrhash (vt-output-buffer-repaints output))
  (setf (vt-output-damage-history output) nil
        (vt-output-frame-sequence output) 0
        (vt-output-current-frame output) nil)
  (values))

(defun disable-vt-output (output)
  "Give the screen back and the descriptor back.  Idempotent.

Closing the scanout restores the CRTC's saved state, destroys the buffers and drops
master (D55's order); the descriptor stays open until that is done, which is why the
two are one function and why the device is closed even if the restore signalled."
  (let ((scanout (vt-output-scanout output)))
    (when (or scanout (vt-output-device output))
      (incf (vt-output-disable-count output))
      (setf (vt-output-scanout output) nil)
      (discard-frame-targets output)
      (forget-vt-frame-history output)
      (unwind-protect
           (when scanout
             (drm:drm-close-scanout scanout))
        (close-vt-device output))))
  (values))

;;; ---------------------------------------------------------------------------
;;; The object a compositor holds
;;; ---------------------------------------------------------------------------

(defun open-vt-output (session &key (path "/dev/dri/card0") connector crtc-id mode
                                      (buffer-count 2) device device-id)
  "Make the card on PATH this compositor's screen, opened through SESSION.

The output registers both hooks itself and enables immediately when the seat is
already enabled -- which is the common case, because the compositor created the
session a moment ago and logind enabled it inside the open call.  That is why
OPEN-VT-OUTPUT, not the first enable callback, is where a compositor learns its
screen size.

CONNECTOR is a name or NIL for the first connected one, CRTC-ID chooses a CRTC, and
MODE defaults to the connector's preferred mode: the same choices DRM-OPEN-SCANOUT
makes, passed through so a compositor can name a screen it wants.  After the first
enable all three are remembered, so a switch back reprograms the same screen.

DEVICE and DEVICE-ID are a card the caller already opened through SESSION, and are
used instead of opening one.  A seat grants DRM master to a single descriptor per VT
activation, so a caller that has already opened the card must hand the descriptor
over rather than have a second one opened beside it.  Most compositors pass neither
and let this function open the card."
  (let ((output (make-instance 'vt-output
                               :session session :path path
                               :connector connector :crtc-id crtc-id :mode mode
                               :buffer-count buffer-count
                               :device device :device-id device-id)))
    (setf (vt-output-enable-hook output)
          (lambda (session)
            (declare (ignore session))
            (enable-vt-output output))
          (vt-output-disable-hook output)
          (lambda (session)
            (declare (ignore session))
            (disable-vt-output output)))
    (session:add-session-enable-hook session (vt-output-enable-hook output))
    (session:add-session-disable-hook session (vt-output-disable-hook output))
    (when (session:session-enabled-p session)
      (handler-case
          (enable-vt-output output)
        (error (condition)
          ;; The hooks must not outlive a failed open either: a session that later
          ;; enables would try to take a screen this compositor has given up on.
          (close-vt-output output)
          (error condition))))
    output))

(defun close-vt-output (output)
  "The undo of OPEN-VT-OUTPUT: the screen back, the descriptor back, the hooks gone.

Idempotent, and safe to call from a signal handler's Lisp wrapper: everything it
does is a close, and every close in this project tolerates being the second one."
  (let ((session (vt-output-session output)))
    (disable-vt-output output)
    (let ((enable (vt-output-enable-hook output))
          (disable (vt-output-disable-hook output)))
      (setf (vt-output-enable-hook output) nil
            (vt-output-disable-hook output) nil)
      (when enable
        (session:remove-session-enable-hook session enable))
      (when disable
        (session:remove-session-disable-hook session disable))))
  t)

;;; ---------------------------------------------------------------------------
;;; One frame
;;; ---------------------------------------------------------------------------
;;
;; The compositor owns the loop and the clock; this is the two calls it makes per
;; frame, so that the buffer choice and the flip stay in the module that knows how
;; many buffers there are.

(defun vt-output-frame-target (output buffer)
  "A render target over BUFFER, made once and kept until OUTPUT is disabled.

The target borrows the buffer's mapping (D58), so it must be destroyed before the
mapping is: DISABLE-VT-OUTPUT does that, in that order."
  (let ((targets (vt-output-targets output)))
    (or (gethash buffer targets)
        (setf (gethash buffer targets) (drm:drm-scanout-target buffer)))))

(defun discard-frame-targets (output)
  (let ((targets (vt-output-targets output)))
    (maphash (lambda (buffer target)
               (declare (ignore buffer))
               (ignore-errors (render:destroy-target target)))
             targets)
    (clrhash targets)))

;;; ---------------------------------------------------------------------------
;;; What each buffer may still be trusted to hold
;;; ---------------------------------------------------------------------------
;;
;; A frame is drawn into a buffer the display is not reading, so with two buffers a
;; frame's pixels are either the last frame's or the one before last: a buffer is at
;; most two frames behind, and "what did this buffer miss?" has an answer (D50).
;;
;; The arithmetic is the nested backend's; the *input* to it is the difference, and
;; that difference is the whole of this slice.  What goes into the history is what
;; changed on the screen -- what a frame painted relative to the frame before -- and
;; never what a buffer had to repaint because it was whole.  Those look alike until
;; a buffer's first paint: recording that frame as "everything changed" makes every
;; buffer that missed it whole, which makes the next frame's paint whole, which is
;; recorded as "everything changed" again.  A two-buffer scanout alternates buffers
;; by construction (DRM-SCANOUT-NEXT-BUFFER is FRAMES modulo the count), so that
;; loop would never end and the whole output would be repainted every frame (D61).

(defun vt-buffer-repaint-region (output buffer next-frame)
  "What BUFFER has to repaint before frame NEXT-FRAME can be shown from it.

A buffer the card has never been given is painted whole; so is one more than two
frames behind, because the history keeps two entries and would otherwise have to
invent the rest.  Otherwise the answer is the union of the change of every frame
this buffer missed -- and a frame recorded as :FULL (a stacking change, the first
frame) makes any buffer that missed it whole, because after a wholesale repaint
that buffer's pixels are unknown rather than partly known.

The returned region belongs to OUTPUT and is reused for that buffer, so a caller
must either merge it into its own region or draw before the next prepare."
  (let ((last (gethash buffer (vt-output-buffer-frames output))))
    (cond
      ((null last) :full)
      ((> (- next-frame last) 2) :full)
      (t
       (let* ((missed (- next-frame last 1))
              (entries (remove-if (lambda (entry) (<= (car entry) last))
                                  (vt-output-damage-history output))))
         (cond
           ;; The history has to cover every frame between LAST and NEXT, or there
           ;; is a frame whose change nobody kept.
           ((< (length entries) missed) :full)
           ((some (lambda (entry) (null (cdr entry))) entries) :full)
           (t
            (let ((region (or (gethash buffer (vt-output-buffer-repaints output))
                              (setf (gethash buffer (vt-output-buffer-repaints output))
                                    (render:make-region)))))
              (render:region-clear region)
              (dolist (entry entries)
                (render:region-union region region (cdr entry)))
              region))))))))

(defun record-vt-frame-damage (output frame change)
  "Remember what FRAME changed on the screen: CHANGE, or NIL for `everything'.

The history is the last two changes and no more: with two buffers a buffer can only
be two frames behind, so anything older is a full repaint by definition.  The
regions come from a fixed pair -- frame N uses region N mod 2, which is the entry
about to fall off the end -- so recording a frame allocates nothing."
  (let ((pool (or (vt-output-history-regions output)
                  (setf (vt-output-history-regions output)
                        (list (render:make-region) (render:make-region)))))
        (entry nil))
    (if (null change)
        (setf entry (cons frame nil))
        (let ((region (nth (mod frame 2) pool)))
          (render:region-copy region change)
          (setf entry (cons frame region))))
    ;; Newest first, never more than two: frames arrive in order, so this is a push
    ;; and a truncation, not a sort.  CDDR is out of bounds on a shorter list, which
    ;; is exactly the first two frames.
    (setf (vt-output-damage-history output)
          (let ((entries (cons entry (vt-output-damage-history output))))
            (if (cddr entries)
                (list (first entries) (second entries))
                entries)))
    nil))

(defun render-vt-output (output scene &key damage (background #xFF000000))
  "Draw SCENE into the buffer the next flip will show; return that buffer.

DAMAGE is a device-pixel region or NIL for a full repaint (D50, D58): a damaged
frame paints no background, so what it did not damage keeps the pixels it had.  An
output the seat has disabled has no buffer to draw into, and says so instead of
drawing into memory nothing will ever scan out.

This is the manual frame path, for a REPL or a probe: it does not consume a frame
number and does not record what it painted, so a compositor that wants the damage
history of MAKE-VT-FRAME-HOOKS uses those hooks and not this."
  (let ((scanout (vt-output-scanout output)))
    (unless scanout
      (error "this output is disabled: the seat has not given its card back yet"))
    (let* ((buffer (drm:drm-scanout-next-buffer scanout))
           (target (vt-output-frame-target output buffer)))
      (unless damage
        (render:fill-target target background))
      (scene:scene-render-items scene target :damage damage)
      buffer)))

(defun present-vt-output (output &key (timeout-ms 1000))
  "Flip to the buffer RENDER-VT-OUTPUT drew into and wait for the kernel's vblank.

Waiting is the whole of this call: the next frame is drawn into the other buffer,
which is why there are two, and a frame drawn into the buffer being scanned out
would tear."
  (let ((scanout (vt-output-scanout output)))
    (unless scanout
      (error "this output is disabled: there is nothing to present on"))
    (drm:drm-scanout-present-next scanout :timeout-ms timeout-ms)))

(defun make-vt-frame-hooks (output)
  "The two functions a compositor needs to render into OUTPUT; values PREPARER PRESENTER.

CF's compositor seam (docs/framework.md §2): the preparer answers which target this
frame draws into and the least that buffer can be trusted to keep, and the presenter
is told after the pixels are in it, so drawing and flipping stay in that order (D58).

The second answer is not :FULL every time: each buffer keeps its own damage history
(VT-BUFFER-REPAINT-REGION), so a buffer that was drawn two frames ago needs the change
of the frame it missed, and the compositor merges that with what changed since its own
last frame.  The presenter records the *compositor's* change -- not the merged region
-- because that is what the other buffer will owe when it comes round (D61); a frame
with nothing to show does not flip at all, since a flip costs a vblank's wait and
paints no pixels (D50)."
  (values (lambda (compositor)
            (declare (ignore compositor))
            (let ((scanout (vt-output-scanout output)))
              (when scanout
                (let* ((buffer (drm:drm-scanout-next-buffer scanout))
                       (next-frame (1+ (vt-output-frame-sequence output))))
                  ;; MULTIPLE-VALUE-PROG1, not PROG1: the preparer answers two values
                  ;; and PROG1 keeps only the first -- which silently turns every
                  ;; "paint this buffer whole" into "there is nothing to trust with"
                  ;; and then, one frame later, into "paint nothing".
                  (multiple-value-prog1
                      (values (vt-output-frame-target output buffer)
                              (vt-buffer-repaint-region output buffer next-frame))
                    ;; The frame number is consumed before the draw and recorded on the
                    ;; buffer before the present, so the history and the next prepare
                    ;; agree about this buffer's age even when nothing is flipped.
                    (setf (vt-output-frame-sequence output) next-frame
                          (vt-output-current-frame output) next-frame)
                    (setf (gethash buffer (vt-output-buffer-frames output))
                          next-frame))))))
          (lambda (compositor target damage)
            (declare (ignore target))
            (when (vt-output-enabled-p output)
              (let ((frame (vt-output-current-frame output)))
                (when frame
                  (record-vt-frame-damage
                   output frame
                   (let ((change (headless:compositor-frame-change compositor)))
                     (if (eq change :full) nil change)))
                  (unless (and (not (eq damage :full))
                               (render:region-empty-p damage))
                    (present-vt-output output))))))))

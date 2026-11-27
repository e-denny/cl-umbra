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
;;;; What it does not do: no reactor source, no frame loop, no damage tracking.  A
;;;; compositor asks for a target, draws, presents, and the seat does the rest.

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
   (device :initform nil :accessor vt-output-device)
   (device-id :initform nil :accessor vt-output-device-id)
   (scanout :initform nil :accessor vt-output-scanout)
   ;; One render target per scanout buffer, made on first use and kept until the
   ;; output is disabled: a target borrows a buffer's mapping, so making one per
   ;; frame would be a pixman image per frame for nothing.
   (targets :initform (make-hash-table :test #'eq) :reader vt-output-targets)
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
    (multiple-value-bind (device id)
        (open-vt-device output session (vt-output-path output))
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
      (unwind-protect
           (when scanout
             (drm:drm-close-scanout scanout))
        (close-vt-device output))))
  (values))

;;; ---------------------------------------------------------------------------
;;; The object a compositor holds
;;; ---------------------------------------------------------------------------

(defun open-vt-output (session &key (path "/dev/dri/card0") connector crtc-id mode
                                      (buffer-count 2))
  "Make the card on PATH this compositor's screen, opened through SESSION.

The output registers both hooks itself and enables immediately when the seat is
already enabled -- which is the common case, because the compositor created the
session a moment ago and logind enabled it inside the open call.  That is why
OPEN-VT-OUTPUT, not the first enable callback, is where a compositor learns its
screen size.

CONNECTOR is a name or NIL for the first connected one, CRTC-ID chooses a CRTC, and
MODE defaults to the connector's preferred mode: the same choices DRM-OPEN-SCANOUT
makes, passed through so a compositor can name a screen it wants.  After the first
enable all three are remembered, so a switch back reprograms the same screen."
  (let ((output (make-instance 'vt-output
                               :session session :path path
                               :connector connector :crtc-id crtc-id :mode mode
                               :buffer-count buffer-count)))
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

(defun render-vt-output (output scene &key damage (background #xFF000000))
  "Draw SCENE into the buffer the next flip will show; return that buffer.

DAMAGE is a device-pixel region or NIL for a full repaint (D50, D58): a damaged
frame paints no background, so what it did not damage keeps the pixels it had.  An
output the seat has disabled has no buffer to draw into, and says so instead of
drawing into memory nothing will ever scan out."
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
frame draws into, and the presenter is told after the pixels are in it, so drawing
and flipping stay in that order (D58).

The preparer answers :FULL every time, and that is the honest state of this backend
rather than a shortcut: with two buffers, the one this frame draws into holds the
frame before last, so a region computed against the last frame is not damage to
*this* buffer.  Per-buffer damage history -- what the nested backend keeps -- is the
next slice's job; a full repaint is correct, and costs a full redraw per frame."
  (values (lambda (compositor)
            (declare (ignore compositor))
            (let ((scanout (vt-output-scanout output)))
              (when scanout
                (values (vt-output-frame-target
                         output (drm:drm-scanout-next-buffer scanout))
                        :full))))
          (lambda (compositor target damage)
            (declare (ignore compositor target damage))
            (when (vt-output-enabled-p output)
              (present-vt-output output)))))

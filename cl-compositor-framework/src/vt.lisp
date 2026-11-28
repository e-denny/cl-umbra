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
   ;; Whether the connector was named by a person or chosen by the card, because the
   ;; two deserve different answers when a cable moves: a named connector is waited
   ;; for, an automatic one follows whatever is connected now (D62).
   (connector-explicit-p :initarg :connector-explicit-p :initform nil
                         :reader vt-output-connector-explicit-p)
   ;; What the card said about that connector when the screen was last programmed, so
   ;; a poll can tell whether the cable moved without keeping a whole inventory (D62).
   (connector-key :initform nil :accessor vt-output-connector-key)
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
   (disables :initform 0 :accessor vt-output-disable-count)
   ;; Evidence for the same reason the two above are: how many times a cable changing
   ;; made this output act.  A poll that finds nothing does not count (D62).
   (hotplugs :initform 0 :accessor vt-output-hotplug-count)
   ;; The machine's two clocks as they were at the last iteration, so a gap between
   ;; them -- the time the machine was suspended -- can be noticed at all (D63).
   (last-boottime :initform nil :accessor vt-output-last-boottime)
   (last-monotonic :initform nil :accessor vt-output-last-monotonic)
   (sleep-gap :initform 0 :accessor vt-output-sleep-gap)
   (resumes :initform 0 :accessor vt-output-resume-count)
   ;; A per-frame line into a stream, for a person diagnosing the screen from the
   ;; console (TINYWL_FRAME_LOG).  NIL is the default and writes nothing; the shape
   ;; of the line is FORMAT-VT-FRAME-LINE's, and it is what a flicker report is
   ;; read with.
   (frame-log :initform nil :accessor vt-output-frame-log)
   (frame-log-last-flip :initform nil :accessor vt-output-frame-log-last-flip)
   ;; What the preparer was asked to answer for the frame being drawn, so the
   ;; presenter can write it down: which buffer, and what that buffer had to owe.
   (current-buffer :initform nil :accessor vt-output-current-buffer)
   (current-required :initform nil :accessor vt-output-current-required))
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

(defun vt-output-screen-p (output)
  "True when OUTPUT has a screen on it now.

The same question ENABLED-P answers, said the other way round because the hotplug
path has a state ENABLED-P cannot name on its own: a card still held with no screen
on it, which is a cable that was pulled (D62)."
  (and (vt-output-scanout output) t))

(defun vt-output-current-connector (output inventory)
  "The connector OUTPUT should be showing on, given what INVENTORY says now.

An explicitly named connector is waited for: if it is gone this is NIL, and the
screen stays given back until it returns.  One chosen automatically follows the card
-- the remembered connector while it is still connected, and otherwise the first
connected one, which is what OPEN-VT-OUTPUT would choose today (D62)."
  (let* ((name (vt-output-connector-name output))
         (remembered (and name (drm:drm-inventory-connector inventory name))))
    (cond
      ((vt-output-connector-explicit-p output)
       (and remembered (drm:drm-connector-connected-p remembered) remembered))
      ((and remembered (drm:drm-connector-connected-p remembered)) remembered)
      (t (first (drm:drm-inventory-connected-connectors inventory))))))

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

(defun revalidate-vt-screen (output device)
  "Forget a remembered connector or mode this card no longer offers.

A cable pulled and put back can be the same monitor in the same socket, a different
monitor in it, or the same monitor in another port.  A remembered mode is kept only
while the connector still lists it, so a new monitor is programmed with its own
preferred mode instead of one it does not have; an automatic connector that is gone
is forgotten altogether, because the card, not the person, chose it (D62)."
  (let* ((inventory (drm:drm-inventory device))
         (name (vt-output-connector-name output))
         (connector (and name (drm:drm-inventory-connector inventory name))))
    (cond
      ((null connector)
       (unless (vt-output-connector-explicit-p output)
         (setf (vt-output-connector-name output) nil
               (vt-output-crtc-id output) nil
               (vt-output-mode output) nil)))
      ((not (drm:drm-connector-connected-p connector))
       ;; The name stays: whether to wait or move on is PUMP-VT-HOTPLUG's decision.
       nil)
      (t
       (let ((mode (vt-output-mode output)))
         (when (and mode
                    (not (find (drm:drm-mode-name mode)
                               (drm:drm-connector-modes connector)
                               :key #'drm:drm-mode-name :test #'string=)))
           (setf (vt-output-mode output) nil)))))))

(defun enable-vt-output (output &key quiet-p)
  "Take the card through the seat and program the screen.  Idempotent.

Doing this twice is not an error -- an enable callback that arrives after the
compositor already enabled by hand is the seat being correct, not the compositor
being wrong -- so an enabled output returns itself.

A failure anywhere after the descriptor arrived puts the descriptor back and
re-signals: the screen is not half taken, and the seat is not asked to close what
the compositor still holds.  QUIET-P is for the two callers that are not a person's
command -- the seat's enable hook, and a poll that found the cable back -- where `no
connector this output may program' is a state to stay in, not an error to raise
(D62)."
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
      ;; A poll that found no cable, or a seat enable after a switch during which the
      ;; cable was pulled: stay screenless with the descriptor held, which is the state
      ;; PUMP-VT-HOTPLUG leaves the output in and the state it can ask its way out of.
      (when (and quiet-p
                 (null (vt-output-current-connector
                        output (drm:drm-inventory device))))
        (return-from enable-vt-output output))
      (handler-case
          (progn
            (revalidate-vt-screen output device)
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
                    (vt-output-height output) (drm:drm-scanout-height scanout)
                    ;; What the cable looked like when this screen was programmed: the
                    ;; poll's next answer is compared against it, not against the card's
                    ;; opinion at some later moment (D62).
                    (vt-output-connector-key output)
                    (drm:drm-connector-hotplug-key
                     (drm:drm-scanout-connector scanout)))
              (incf (vt-output-enable-count output))
              output))
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
        (vt-output-current-frame output) nil
        (vt-output-current-buffer output) nil
        (vt-output-current-required output) nil)
  ;; A flip clock that counted across a VT switch would report the gap since the last
  ;; frame before somebody else had the screen as this frame's period.
  (setf (vt-output-frame-log-last-flip output) nil)
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
;;; Hotplug (D62)
;;; ---------------------------------------------------------------------------

(defun blank-vt-output (output)
  "Give the screen back and keep the card: a cable was pulled, a VT was not left.

DISABLE-VT-OUTPUT closes the descriptor because a VT switch revokes it anyway.  Here
the descriptor is the only way to ask whether the cable came back, and reopening it
through the seat once a second would be a logind round trip per poll; so the scanout
goes back (CRTC restored, buffers destroyed), the frame history goes with the buffers
(D61 decision 4), and the descriptor stays."
  (let ((scanout (vt-output-scanout output)))
    (when scanout
      (setf (vt-output-scanout output) nil)
      (discard-frame-targets output)
      (forget-vt-frame-history output)
      (drm:drm-close-scanout scanout))
    (values)))

(defun adopt-vt-connector (output connector)
  "Remember CONNECTOR as the screen's socket, unless it already is.

A connector that is not the one remembered is a different socket (the automatic
choice moved), so the CRTC and the mode remembered against the old one no longer
apply and are forgotten with it."
  (let ((name (drm:drm-connector-name connector)))
    (unless (and (vt-output-connector-name output)
                 (string= name (vt-output-connector-name output)))
      (setf (vt-output-connector-name output) name
            (vt-output-crtc-id output) nil
            (vt-output-mode output) nil))))

(defun pump-vt-hotplug (output)
  "Ask the card what is plugged in, and put the screen right if it changed.

Returns one of

  :UNCHANGED     nothing about this output's connector changed -- the usual answer,
                 and the one a cable that is still out keeps giving
  :UNPLUGGED     the connector went away, so the screen was given back and the card kept
  :REPLUGGED     a screen is back: this output has one again
  :REPROGRAMMED  the connector stayed but what it offers changed, and the screen was
                 programmed again -- a different monitor on the same cable is this
  :FAILED        there was a screen to take and the card refused it; the state is left
                 for the next poll, which asks again
  :NO-CARD       no descriptor this poll may use (the seat is disabled, or a cable is
                 out and the card is held waiting for it)

The caller owns the clock: this is one question, not a loop (D59).  The comparison is
against what the card said when the screen was last programmed, so an unchanged
answer touches nothing but a read of the connector list."
  (labels ((attempt-enable ()
             ;; QUIET-P: "no cable" is a state to wait in, not an error; anything else
             ;; the card refuses is reported as :FAILED, and the descriptor is closed by
             ;; ENABLE-VT-OUTPUT's own error path, so the next poll starts over.
             (handler-case
                 (progn (enable-vt-output output :quiet-p t)
                        (and (vt-output-screen-p output) t))
               (error () nil))))
    (if (null (vt-output-device output))
        ;; No descriptor: either the seat is disabled (a VT switch; its enable hook
        ;; will take the screen back), or a previous attempt failed and left nothing
        ;; open.  Retrying here is what makes a refused modeset recoverable.
        (if (and (session:session-enabled-p (vt-output-session output))
                 (attempt-enable))
            :replugged
            :no-card)
        (let* ((inventory (drm:drm-inventory (vt-output-device output)))
               (connector (vt-output-current-connector output inventory))
               (key (and connector (drm:drm-connector-hotplug-key connector)))
               (remembered (vt-output-connector-key output))
               (screen (vt-output-screen-p output)))
          (cond
            ((equal key remembered) :unchanged)
            ((null connector)
             (setf (vt-output-connector-key output) nil)
             (if screen
                 (progn (incf (vt-output-hotplug-count output))
                        (blank-vt-output output)
                        :unplugged)
                 :no-card))
            ((null screen)
             (incf (vt-output-hotplug-count output))
             (adopt-vt-connector output connector)
             (if (attempt-enable) :replugged :failed))
            (t
             (incf (vt-output-hotplug-count output))
             (adopt-vt-connector output connector)
             (blank-vt-output output)
             (if (attempt-enable) :reprogrammed :failed)))))))

;;; ---------------------------------------------------------------------------
;;; Resume (D63)
;;; ---------------------------------------------------------------------------
;;
;; Nothing in this stack is told that the machine slept.  logind's PrepareForSleep is
;; a D-Bus signal, and there is no D-Bus client here for the same reason there is no
;; udev one (D62); libseat's listener has enable and disable and nothing else (its own
;; header says so).  What is left is the clock: CLOCK_BOOTTIME counts through a
;; suspend and CLOCK_MONOTONIC does not, so the difference between them is exactly the
;; time the machine spent asleep -- and it does not move for an NTP step, because
;; neither clock does.

(defun resume-gap (boottime monotonic last-boottime last-monotonic)
  "Seconds the machine spent suspended between two readings, or NIL if unknown.

Pure, so the arithmetic is a test rather than a comment: BOOTTIME-THEN and
MONOTONIC-THEN are the previous iteration's readings."
  (when (and last-boottime last-monotonic)
    (max 0 (- (- boottime last-boottime) (- monotonic last-monotonic)))))

(defun vt-output-crtc-ours-p (output)
  "Is the CRTC still scanning out one of this output's buffers?

A resume may have left the kernel showing something else -- the console, or a
framebuffer it restored from before this compositor existed -- and the only way to
know is to ask the card, which GETCRTC answers without master."
  (let* ((device (vt-output-device output))
         (scanout (vt-output-scanout output))
         (crtc-id (vt-output-crtc-id output)))
    (and device scanout crtc-id
         (handler-case
             (let* ((state (drm:drm-crtc-state device crtc-id))
                    (front (drm:drm-scanout-buffer scanout
                                                   (drm:drm-scanout-front scanout))))
               (and (drm:drm-crtc-mode-valid-p state)
                    (= (drm:drm-crtc-buffer-id state)
                       (drm:dumb-buffer-framebuffer-id front))))
           (drm:drm-error () nil)))))

(defun pump-vt-resume (output &key (boottime (ffi:boottime-seconds))
                                       (monotonic (ffi:monotonic-seconds))
                                       (threshold 2))
  "Notice a suspend that happened since the last call, and answer what to do.

Returns one of

  :AWAKE         the clocks agree: the machine did not sleep
  :RESUMED       it slept; the CRTC is still ours, and the frame history is forgotten
                 so that the next frame repaints everything -- the pixels on the
                 screen are not this compositor's any more, even though the state is
  :REPROGRAMMED  it slept and the CRTC was not ours (or had no mode); the screen was
                 programmed again with this output's connector and mode, and the next
                 frame is full
  :NO-CARD       it slept, but there is no descriptor to check with (the seat was
                 disabled while we were away); the enable hook will program the screen

The caller owns the clock and must call this once per loop iteration: it is two
clock_gettime calls in the usual case, which is why it is not on the hotplug's
one-second cadence (D63)."
  (let ((gap (resume-gap boottime monotonic
                         (vt-output-last-boottime output)
                         (vt-output-last-monotonic output))))
    (setf (vt-output-last-boottime output) boottime
          (vt-output-last-monotonic output) monotonic)
    (cond
      ((null (vt-output-device output)) :no-card)
      ((and gap (>= gap threshold))
       (incf (vt-output-resume-count output))
       (setf (vt-output-sleep-gap output) gap)
       ;; The buffers' pixels may not have survived the sleep: whatever the CRTC is
       ;; showing, nothing in them can be trusted to still be there.
       (forget-vt-frame-history output)
       (cond
         ((and (vt-output-screen-p output) (vt-output-crtc-ours-p output))
          :resumed)
         ((vt-output-screen-p output)
          (blank-vt-output output)
          (enable-vt-output output :quiet-p t)
          (if (vt-output-screen-p output) :reprogrammed :no-card))
         (t :no-card)))
      (t :awake))))

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
                               :connector-explicit-p (and connector t)
                               :device device :device-id device-id)))
    (setf (vt-output-enable-hook output)
          ;; QUIET: a VT switch back into a session whose cable is out is a screen to
          ;; wait for, not an error to raise inside the seat's hook (D62).
          (lambda (session)
            (declare (ignore session))
            (enable-vt-output output :quiet-p t))
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
;; by construction (DRM-SCANOUT-NEXT-BUFFER is the buffer the display is not
;; reading, D65), so that loop would never end and the whole output would be
;; repainted every frame (D61).

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

;;; ---------------------------------------------------------------------------
;;; One line per frame, for a flicker that has to be read from the console
;;; ---------------------------------------------------------------------------
;;
;; A screen that flickers when the pointer moves cannot be diagnosed from a
;; photograph of it: the question is which frame, drawn into which buffer, with
;; what damage, arrived when.  So the VT backend can write one line per frame
;; (TINYWL_FRAME_LOG on the command line), and the line carries the four numbers
;; that separate the possible causes:
;;
;;   * SEQ and F are numbers, not pixels: they say whether frames are being
;;     prepared faster than they reach the card -- a skipped frame is a frame
;;     whose pixels are never shown, and a *stale* one is a frame whose pixels are.
;;   * BUF and FRONT say where the frame went.  The rule is that a frame is drawn
;;     where the display is not (D65), so FRONT going 0->1 means the flip landed
;;     on the buffer that was drawn.  FRONT naming the buffer that was *just*
;;     drawn while the event's user-data is not the one this flip was stamped
;;     with is the other case: our bookkeeping is one flip ahead of the kernel,
;;     and then the next frame draws into the buffer the display is reading -- a
;;     tear, which is what a person sees as lines briefly lighter than their
;;     neighbours.
;;   * DMG, CHG and REQ separate three facts that look alike: what this frame has
;;     to paint (the merged damage), what changed on the screen (the compositor's
;;     change, recorded for the other buffer), and what this buffer owes because
;;     it was not painted last frame.  A REQ that is :FULL on every frame is a
;;     backend painting the screen instead of a region; a REQ that is empty while
;;     CHG is not is a buffer being trusted with pixels it does not have (D61).
;;   * WAIT and GAP are milliseconds: how long the flip's completion took, and how
;;     long since the previous one.  A WAIT near zero on a 60 Hz mode is the kernel
;;     answering without a vblank -- no tear protection at all -- and a GAP far
;;     above the mode's frame time is a frame the loop could not keep up with.

(defun format-vt-frame-box (box)
  "BOX as a line's field: EMPTY, FULL, or X,Y,W,H."
  (cond ((null box) "empty")
        ((eq box :full) "full")
        (t (format nil "~D,~D,~D,~D" (first box) (second box)
                   (third box) (fourth box)))))

(defun format-vt-frame-line (&key frame sequence buffer front-before front-after
                                  damage change required client flip kernel-sequence
                                  user-data expected-user-data draw-ms wait-ms gap-ms)
  "One frame as one line; pure, so its shape is a test.

FLIP is false for a frame that painted nothing and was not presented.  The two
user-data numbers are the diagnostic: equal means the completion was this flip's,
and a smaller one means the wait was satisfied by a flip that came before it.

CLIENT is what the clients said they painted, which is not CHG: CHG also holds what
the compositor inferred from a node moving or a buffer being swapped, and a client
that damages nothing is an empty CLIENT and a whole window of CHG if it swapped
buffers."
  (concatenate
   'string
   (format nil "vt-frame f=~D seq=~D buf=~D front=~D->~D dmg=~A chg=~A cli=~A req=~A"
           frame sequence buffer front-before front-after
           (format-vt-frame-box damage) (format-vt-frame-box change)
           (format-vt-frame-box client) (format-vt-frame-box required))
   (if (null flip)
       " flip=none"
       (format nil " flip=ud=~@[~D~]/~@[~D~] kseq=~@[~D~] draw=~,1Fms wait=~,1Fms ~
gap=~,1Fms"
               user-data expected-user-data kernel-sequence
               (or draw-ms 0.0) (or wait-ms 0.0) (or gap-ms -1.0)))))

(defun write-vt-frame-line (stream line)
  "Write LINE and flush it: a log read while the compositor runs must be current."
  (write-line line stream)
  (finish-output stream)
  line)

(defun make-vt-frame-hooks (output &key frame-log)
  "The two functions a compositor needs to render into OUTPUT; values PREPARER PRESENTER.

FRAME-LOG, when given, is a stream this backend writes one line per frame to (see
FORMAT-VT-FRAME-LINE); it changes nothing else about the frame.

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
  (when frame-log
    (setf (vt-output-frame-log output) frame-log))
  (values (lambda (compositor)
            (declare (ignore compositor))
            (let ((scanout (vt-output-scanout output)))
              (when scanout
                (let* ((buffer (drm:drm-scanout-next-buffer scanout))
                       (next-frame (1+ (vt-output-frame-sequence output)))
                       ;; Asked before this buffer's recorded frame moves: the answer
                       ;; is "what has it missed", and after the SETF it would
                       ;; always be "nothing".
                       (required (vt-buffer-repaint-region output buffer next-frame)))
                  ;; The frame number is consumed before the draw and recorded on the
                  ;; buffer before the present, so the history and the next prepare
                  ;; agree about this buffer's age even when nothing is flipped.
                  (setf (vt-output-frame-sequence output) next-frame
                        (vt-output-current-frame output) next-frame
                        (vt-output-current-buffer output) buffer
                        (vt-output-current-required output)
                        (if (eq required :full) :full (render:region-bounds required)))
                  (setf (gethash buffer (vt-output-buffer-frames output))
                        next-frame)
                  (values (vt-output-frame-target output buffer) required)))))
          (lambda (compositor target damage)
            (declare (ignore target))
            (when (vt-output-enabled-p output)
              (let ((frame (vt-output-current-frame output))
                    (log (vt-output-frame-log output)))
                (when frame
                  (let* ((change (headless:compositor-frame-change compositor))
                         (change-box (if (eq change :full)
                                         :full
                                         (render:region-bounds change)))
                         (scanout (vt-output-scanout output))
                         (present-p (not (and (not (eq damage :full))
                                              (render:region-empty-p damage))))
                         (front-before (drm:drm-scanout-front scanout))
                         (event nil)
                         (wait-ms nil)
                         (gap-ms nil))
                    (record-vt-frame-damage
                     output frame
                     (if (eq change :full) nil change))
                    (when present-p
                      (let ((started (ffi:monotonic-seconds)))
                        (setf event (present-vt-output output)
                              wait-ms (* 1000 (- (ffi:monotonic-seconds) started)))
                        ;; The gap is measured from the previous flip's *queue*, so
                        ;; it is the frame period and not the period plus a wait
                        ;; that the last frame's own wait already accounted for.
                        (when (vt-output-frame-log-last-flip output)
                          (setf gap-ms (* 1000 (- started
                                                  (vt-output-frame-log-last-flip output)))))
                        (setf (vt-output-frame-log-last-flip output) started)))
                    (when log
                      (write-vt-frame-line
                       log
                       (format-vt-frame-line
                        :frame frame
                        :sequence (vt-output-frame-sequence output)
                        :buffer (position (vt-output-current-buffer output)
                                          (drm:drm-scanout-buffers scanout))
                        :front-before front-before
                        :front-after (drm:drm-scanout-front scanout)
                        :damage (if (eq damage :full)
                                    :full
                                    (render:region-bounds damage))
                        :change change-box
                        :client (headless:compositor-client-damage compositor)
                        :draw-ms (headless:compositor-draw-ms compositor)
                        :required (vt-output-current-required output)
                        :flip present-p
                        :kernel-sequence (and event (getf event :sequence))
                        :user-data (and event (getf event :user-data))
                        :expected-user-data
                        (and event (drm:drm-device-flips
                                    (drm:drm-scanout-device scanout)))
                        :wait-ms wait-ms
                        :gap-ms gap-ms))))))))))

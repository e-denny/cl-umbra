;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The phase-3 gate: a real xdg-shell client -- weston-simple-shm, with its own
;;;; libwayland -- binds xdg_wm_base, is configured, acks, attaches a buffer and
;;;; draws through our compositor.
;;;;
;;;; Run by scripts/xdg-shell-gate.sh, which sets up a private runtime directory
;;;; and compiles nothing: weston-simple-shm is a system binary and is the point.
;;;; The environment carries WESTON_CLIENT (the binary) and FRAME_PNG.
;;;;
;;;; What is asserted, and why each assertion is a real one:
;;;;
;;;;   * the toplevel exists and is mapped        -- the handshake completed;
;;;;   * a configure was sent and acked           -- and *our* serial was consumed,
;;;;                                                 not a number we guessed;
;;;;   * xdg_wm_base.ping came back as pong      -- the client hears us and we hear
;;;;                                                 it, in both directions;
;;;;   * the client is still alive at the end    -- no protocol error, no
;;;;                                                 disconnect, no internal error;
;;;;   * pixels inside the window rect are not background and there are none
;;;;     outside it                              -- the buffer we received is the
;;;;                                                 one that got drawn, at its own
;;;;                                                 size, in the right place.
;;;;
;;;; The client is a loop, not a one-shot program: weston-simple-shm redraws
;;;; forever, so the gate runs it for a number of frames and then asks it to stop.
;;;; "Exits 0 by itself" would be a claim about weston, not about us.

;; The source registry and Quicklisp are set up by scripts/lib.sh, which the
;; driver has already sourced.
(asdf:load-system "cl-compositor-framework")

(in-package #:cl-user)

(defparameter *background* #xFF000000 "Opaque black: nothing drawn there.")

(defun resources-of-type (compositor type)
  "Every live RESOURCE of TYPE across the compositor's clients, newest first."
  (loop for client in (wayland.server:display-clients (cf:compositor-display compositor))
        append (remove-if-not (lambda (resource) (typep resource type))
                              (wayland.server:client-resources client))))

(defun first-toplevel (compositor)
  (first (resources-of-type compositor 'wayland.server:xdg-toplevel)))

(defun pump (compositor seconds)
  "Run the compositor's reactor for SECONDS of wall-clock time."
  (let ((deadline (+ (get-internal-real-time)
                     (* seconds internal-time-units-per-second)))
        (display (cf:compositor-display compositor)))
    (loop until (> (get-internal-real-time) deadline)
          do (wayland.server:run-once display :timeout 0.01))))

(defun pump-until (compositor predicate seconds)
  "Pump until PREDICATE returns true, or SECONDS pass; returns the predicate value."
  (let ((deadline (+ (get-internal-real-time)
                     (* seconds internal-time-units-per-second)))
        (display (cf:compositor-display compositor)))
    (loop
      (let ((value (funcall predicate)))
        (when value (return value))
        (when (> (get-internal-real-time) deadline)
          (return nil))
        (wayland.server:run-once display :timeout 0.01)))))

(defun count-colours (compositor)
  "The distinct pixels in the target, and how many are not the background.

Two numbers, because either alone can lie: a frame of one wrong colour is still
\"not background\", and a frame of one right colour is still one colour."
  (let ((seen (make-hash-table :test #'eql))
        (lit 0)
        (width (cf:compositor-width compositor))
        (height (cf:compositor-height compositor)))
    (dotimes (y height)
      (dotimes (x width)
        (let ((pixel (cf:frame-pixel compositor x y)))
          (setf (gethash pixel seen) t)
          (unless (= pixel *background*)
            (incf lit)))))
    (values (hash-table-count seen) lit)))

(defun count-lit-outside (compositor width height)
  "Pixels that are not the background and lie outside a WIDTHxHEIGHT window at 0,0."
  (let ((lit 0))
    (dotimes (y (cf:compositor-height compositor))
      (dotimes (x (cf:compositor-width compositor))
        (when (and (or (>= x width) (>= y height))
                   (/= (cf:frame-pixel compositor x y) *background*))
          (incf lit))))
    lit))

(let* ((client (or (uiop:getenv "WESTON_CLIENT")
                   (error "WESTON_CLIENT is not set")))
       (png (or (uiop:getenv "FRAME_PNG") "/tmp/cl-wayland-xdg.png"))
       (compositor (cf:make-headless-compositor :width 256 :height 256
                                                :background *background*))
       (display (cf:compositor-display compositor))
       (process nil)
       (ok t))

  (flet ((fail (control &rest arguments)
           (setf ok nil)
           (format t "  FAIL ~?~%" control arguments)))

    (unwind-protect
         (progn
           (format t "compositor: 256x256 headless, socket ~A~%"
                   (wayland.server:display-socket-path display))
           (format t "client: ~A~%" client)
           (setf process (sb-ext:run-program client nil :wait nil :output t :error t))

           ;; 1. The client must get as far as drawing: frames come only after a
           ;;    commit with a buffer, which comes only after configure + ack.
           (let ((frames (pump-until compositor
                                     (lambda () (>= (cf:compositor-frame-count compositor) 5))
                                     20)))
             (unless frames
               (fail "only ~D frame(s) in 20 s; the client is stuck waiting for something"
                     (cf:compositor-frame-count compositor))))

           ;; 2. The handshake, from our side of the wire.
           (let ((toplevel (first-toplevel compositor)))
             (if (null toplevel)
                 (fail "no xdg_toplevel was created")
                 (let ((shell (wayland.server:xdg-toplevel-shell-surface toplevel))
                       (surface (wayland.server:xdg-surface-surface
                                 (wayland.server:xdg-toplevel-shell-surface toplevel))))
                   (format t "toplevel ~D: title ~S app-id ~S mapped ~S configure ~D~%"
                           (wayland.server:resource-id toplevel)
                           (wayland.server:xdg-toplevel-title toplevel)
                           (wayland.server:xdg-toplevel-app-id toplevel)
                           (wayland.server:xdg-toplevel-mapped-p toplevel)
                           (wayland.server:xdg-toplevel-configure-count toplevel))
                   (format t "xdg_surface ~D: configured ~S acked ~S acks ~D serials ~S~%"
                           (wayland.server:resource-id shell)
                           (wayland.server:xdg-surface-configured-p shell)
                           (wayland.server:xdg-surface-acknowledged-p shell)
                           (wayland.server:xdg-surface-ack-count shell)
                           (wayland.server:xdg-surface-pending-serials shell))
                   (unless (wayland.server:xdg-surface-configured-p shell)
                     (fail "no configure was sent"))
                   (unless (plusp (wayland.server:xdg-surface-ack-count shell))
                     (fail "the client never acked a configure serial"))
                   (unless (wayland.server:xdg-toplevel-mapped-p toplevel)
                     (fail "the toplevel never mapped"))
                   (unless (wayland.server:xdg-toplevel-title toplevel)
                     (fail "the client never set a title"))
                   ;; Every configure this compositor sends carries 0x0: it has
                   ;; no layout, so the client chooses its own size.  The *second*
                   ;; configure is the one focus-on-map produces, and it says the
                   ;; toplevel is activated (the seat gate checks that in detail);
                   ;; the empty initial state array is asserted by the unit suite,
                   ;; which can look at the first configure rather than the last.
                   (unless (and (zerop (wayland.server:xdg-toplevel-configure-width toplevel))
                                (zerop (wayland.server:xdg-toplevel-configure-height toplevel)))
                     (fail "the configure was ~Dx~D, not 0x0 (you choose)"
                           (wayland.server:xdg-toplevel-configure-width toplevel)
                           (wayland.server:xdg-toplevel-configure-height toplevel)))
                   (unless (member wayland.server:+xdg-toplevel-state-activated+
                                   (wayland.server:xdg-toplevel-configure-states toplevel))
                     (fail "the focused toplevel was never configured as activated: ~S"
                           (wayland.server:xdg-toplevel-configure-states toplevel)))
                   (unless (and surface (wayland.server:surface-current-buffer surface))
                     (fail "no buffer was ever committed")))))

           ;; 3. Ping/pong: both directions of a serial, on our own numbers.
           (let ((wm-base (first (cf:compositor-shells compositor))))
             (if (null wm-base)
                 (fail "no xdg_wm_base was bound")
                 (progn
                   (let ((serial (wayland.server:ping-xdg-wm-base wm-base)))
                     (unless (pump-until compositor
                                         (lambda ()
                                           (plusp (wayland.server:xdg-wm-base-pong-count wm-base)))
                                         5)
                       (fail "no pong for ping serial ~D" serial))
                     (format t "ping ~D answered (~D ping~:P, ~D pong~:P)~%"
                             serial
                             (wayland.server:xdg-wm-base-ping-count wm-base)
                             (wayland.server:xdg-wm-base-pong-count wm-base))))))

           ;; 4. The client is still connected: every check above would have been
           ;;    followed by a disconnect if we had sent wl_display.error.
           (if (sb-ext:process-alive-p process)
               (format t "client alive after the handshake~%")
               (fail "the client died (code ~S)" (sb-ext:process-exit-code process)))

           ;; 5. Pixels.  The window's size is whatever the client chose after our
           ;;    0x0 configure, so take it from the buffer we received.
           (let* ((toplevel (first-toplevel compositor))
                  (shell (and toplevel (wayland.server:xdg-toplevel-shell-surface toplevel)))
                  (surface (and shell (wayland.server:xdg-surface-surface shell)))
                  (buffer (and surface (wayland.server:surface-current-buffer surface))))
             (if (null buffer)
                 (fail "no buffer to measure")
                 (let* ((width (wayland.server:shm-buffer-width buffer))
                        (height (wayland.server:shm-buffer-height buffer)))
                   (multiple-value-bind (colours lit) (count-colours compositor)
                     (let ((outside (count-lit-outside compositor width height)))
                       (format t "buffer ~Dx~D, ~D pixel~:P drawn in the window, ~
~D colour~:P in the frame, ~D pixel~:P outside the window~%"
                               width height lit colours outside)
                       (when (< lit 1000)
                         (fail "the window is (nearly) empty: ~D pixels drawn" lit))
                       (when (< colours 8)
                         (fail "a ~D-colour frame is not a drawn window" colours))
                       (unless (zerop outside)
                         (fail "~D pixel~:P were drawn outside the ~Dx~D window"
                               outside width height)))))))

           (cf:write-frame-png compositor png)
           (format t "screenshot: ~A~%" png)
           (format t "frames rendered: ~D over ~D surface(s)~%"
                   (cf:compositor-frame-count compositor)
                   (length (cf:compositor-surfaces compositor))))

      ;; Ask the client to stop (it is a redraw loop), then prove the teardown
      ;; left nothing behind.  A signal death is the expected outcome; what must
      ;; not happen is a wedge or a leftover client.
      (when process
        (ignore-errors (sb-ext:process-kill process 15))
        (when (pump-until compositor (lambda () (not (sb-ext:process-alive-p process))) 5)
          (format t "client stopped (~S)~%" (sb-ext:process-exit-code process)))
        (ignore-errors (sb-ext:process-close process)))
      (pump compositor 0.2)
      (let ((clients (wayland.server:display-clients display)))
        (if clients
            (progn (setf ok nil)
                   (format t "  FAIL ~D client(s) still connected after the client exited~%"
                           (length clients)))
            (format t "teardown: no clients, no objects left~%")))
      (wayland.server:close-display display)
      (format t "~&~:[FAILED~;PASSED~]~%" ok)
      (uiop:quit (if ok 0 1)))))

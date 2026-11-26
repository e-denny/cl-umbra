;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The popup gate: a real libwayland client opens menus on our compositor.
;;;;
;;;; Run by scripts/popup-gate.sh, which compiles tests/c-client/wayland-popup-client.c
;;;; against xdg-shell generated from our vendored XML.  The client is the peer,
;;;; not the product.
;;;;
;;;; What is asserted, and why each assertion is a real one:
;;;;
;;;;   * a press inside the window opens a popup            -- get_popup, the
;;;;                                                          configure pair, ack and
;;;;                                                          map all happened;
;;;;   * its configure is the positioner's answer           -- (30, 30) for an anchor
;;;;                                                          at the window's corner,
;;;;                                                          which is arithmetic, not
;;;;                                                          a number the client sent;
;;;;   * the popup's pixels are on screen, at that place,
;;;;     over the window's pixels                           -- the node was placed
;;;;                                                          where the configure said;
;;;;   * Escape dismisses it                                -- the grab owns the
;;;;                                                          keyboard and the client
;;;;                                                          gets popup_done;
;;;;   * the second menu is *flipped or slid* inside the
;;;;     output, and the requested place is empty           -- the constraint box the
;;;;                                                          compositor supplied is
;;;;                                                          the output, expressed in
;;;;                                                          the parent's geometry;
;;;;   * a press outside the menu dismisses it and does not
;;;;     reach the client as a click                        -- an owner-events grab
;;;;                                                          that swallowed its own
;;;;                                                          dismissal click.
;;;;
;;;; The output is deliberately small (320x240) compared with the window (300x200),
;;;; because that is what makes the second menu need constraining at all.

(asdf:load-system "cl-compositor-framework")

(in-package #:cl-user)

(defparameter *background* #xFF000000 "Opaque black: nothing drawn there.")
(defparameter *window-colour* #xFF3C8C3C "The toplevel's buffer.")
(defparameter *popup-colour* #xFFCC33CC "The popup's buffer.")

(defvar *failures* 0)

(defun check (value control &rest arguments)
  (if value
      (format t "  ok   ~?~%" control arguments)
      (progn (incf *failures*)
             (format t "  FAIL ~?~%" control arguments)))
  value)

(defun pump (compositor seconds)
  "Run the compositor's reactor for SECONDS of wall-clock time."
  (let ((deadline (+ (get-internal-real-time)
                     (* seconds internal-time-units-per-second)))
        (display (cf:compositor-display compositor)))
    (loop until (> (get-internal-real-time) deadline)
          do (wayland.server:run-once display :timeout 0.01))))

(defun pump-until (compositor predicate seconds)
  "Pump until PREDICATE is true, or SECONDS pass; returns the predicate's value."
  (let ((deadline (+ (get-internal-real-time)
                     (* seconds internal-time-units-per-second)))
        (display (cf:compositor-display compositor)))
    (loop
      (let ((value (funcall predicate)))
        (when value (return value))
        (when (> (get-internal-real-time) deadline)
          (return nil))
        (wayland.server:run-once display :timeout 0.01)))))

(defun resources-of-type (compositor type)
  "Every live RESOURCE of TYPE across the compositor's clients, newest first."
  (loop for client in (wayland.server:display-clients (cf:compositor-display compositor))
        append (remove-if-not (lambda (resource) (typep resource type))
                              (wayland.server:client-resources client))))

(defun live-popups (compositor)
  "The client's popups that have not been dismissed, newest first."
  (remove-if #'wayland.server:xdg-popup-dismissed-p
             (resources-of-type compositor 'wayland.server:xdg-popup)))

(defun click (compositor x y &key (button :left))
  (cf:inject-pointer-motion compositor x y)
  (cf:inject-pointer-button compositor button :pressed)
  (cf:inject-pointer-button compositor button :released)
  (pump compositor 0.05))

(let* ((client (or (uiop:getenv "POPUP_CLIENT")
                   (error "POPUP_CLIENT is not set")))
       (compositor (cf:make-headless-compositor :width 320 :height 240
                                                :background *background*))
       (display (cf:compositor-display compositor))
       (process nil))
  (unwind-protect
       (progn
         (format t "compositor: 320x240 headless, socket ~A~%"
                 (wayland.server:display-socket-path display))
         (format t "client: ~A~%" client)
         (setf process (sb-ext:run-program client nil :wait nil :output t :error t))

         ;; 1. The window maps and is drawn where the framework places the first
         ;;    window: (0, 0) of the cascade.
         (check (pump-until compositor
                            (lambda ()
                              (let ((toplevel (first (resources-of-type
                                                      compositor
                                                      'wayland.server:xdg-toplevel))))
                                (and toplevel (wayland.server:xdg-toplevel-mapped-p toplevel))))
                            20)
                "the client's window mapped")
         (pump compositor 0.2)
         (check (= *window-colour* (cf:frame-pixel compositor 150 100))
                "the window is drawn at (0, 0): (150, 100) is the window's colour")
         (check (= *background* (cf:frame-pixel compositor 310 230))
                "and nothing is drawn outside it")

         ;; 2. A press inside the window opens the first menu.  Its positioner
         ;;    anchors at (10 10 20 20) with bottom-right anchor and gravity, so
         ;;    the popup belongs at (30, 30) -- and it fits, so no constraint
         ;;    adjustment should move it.
         (click compositor 50 50)
         (let ((popup (pump-until compositor
                                  (lambda ()
                                    (let ((popup (first (live-popups compositor))))
                                      (and popup (wayland.server:xdg-popup-geometry popup)
                                           popup)))
                                  20)))
           (check popup "a press in the window opened a popup")
           (when popup
             (check (equal '(30 30 120 80) (wayland.server:xdg-popup-geometry popup))
                    "its configure is the positioner's answer: ~S, got ~S"
                    '(30 30 120 80) (wayland.server:xdg-popup-geometry popup))
             (check (eq (first (resources-of-type compositor 'wayland.server:xdg-toplevel))
                        (wayland.server:xdg-popup-toplevel popup))
                    "the popup belongs to the window")
             (check (typep (cf:compositor-grab compositor) 'cf.grab:popup-grab)
                    "the explicit grab owns the pointer")
             (pump compositor 0.2)
             (check (= *popup-colour* (cf:frame-pixel compositor 35 35))
                    "the popup's pixels are drawn at its configured place")
             (check (= *popup-colour* (cf:frame-pixel compositor 145 105))
                    "all the way to its far corner (145, 105)")
             (check (= *window-colour* (cf:frame-pixel compositor 200 150))
                    "and the window still shows around it")
             (check (= *background* (cf:frame-pixel compositor 305 205))
                    "the place the popup would have had without placement is empty")
             (check (= (cf:frame-pixel compositor 305 205)
                       (cf:frame-pixel compositor 300 200))
                    "and so is everything past the window")

             ;; 3. Escape: the grab consumes it and the client is told.
             (cf:inject-key compositor "Escape" :pressed)
             (cf:inject-key compositor "Escape" :released)
             (check (pump-until compositor
                                (lambda () (wayland.server:xdg-popup-dismissed-p popup))
                                10)
                    "Escape dismissed the popup (popup_done was sent)")
             (pump compositor 0.2)
             (check (= *window-colour* (cf:frame-pixel compositor 35 35))
                    "the popup is off the screen: its pixels are the window's again")
             (check (null (cf:compositor-grab compositor))
                    "and the grab ended with it")))

         ;; 4. A second menu, anchored at the window's bottom-right corner.  At
         ;;    (300, 200) plus 120x80 it would leave a 320x240 output, so the
         ;;    compositor flips it: the anchor becomes top-right and the answer is
         ;;    (170, 110).
         (pump-until compositor (lambda () (null (live-popups compositor))) 10)
         (click compositor 60 60)
         (let ((popup (pump-until compositor
                                  (lambda ()
                                    (let ((popup (first (live-popups compositor))))
                                      (and popup (wayland.server:xdg-popup-geometry popup)
                                           popup)))
                                  20)))
           (check popup "a second press opened the second menu")
           (when popup
             (check (equal '(170 110 120 80) (wayland.server:xdg-popup-geometry popup))
                    "the constrained menu was flipped inside the output: ~S, got ~S"
                    '(170 110 120 80) (wayland.server:xdg-popup-geometry popup))
             (pump compositor 0.2)
             (check (= *popup-colour* (cf:frame-pixel compositor 175 115))
                    "its pixels are where the flipped configure says")
             (check (= *popup-colour* (cf:frame-pixel compositor 285 185))
                    "to its far corner (285, 185)")
             (check (= *background* (cf:frame-pixel compositor 305 205))
                    "and the requested place -- past the output's corner -- is empty")

             ;; 5. A press outside the menu dismisses it, and is swallowed: the
             ;;    client must not see a click for a menu that has already closed.
             (click compositor 250 20)
             (check (pump-until compositor
                                (lambda () (wayland.server:xdg-popup-dismissed-p popup))
                                10)
                    "a press outside the menu dismissed it")
             (pump compositor 0.2)
             (check (= *window-colour* (cf:frame-pixel compositor 175 115))
                    "the menu is off the screen")
             (check (null (cf:compositor-grab compositor)) "and nothing is grabbing")))

         (check (sb-ext:process-alive-p process) "the client is still connected")
         (when (plusp *failures*)
           (format t "~%  the client said:~%~{    ~A~%~}"
                   (loop for line = (read-line (sb-ext:process-output process)
                                               nil nil)
                         while line collect line))))
    (when process
      (ignore-errors (sb-ext:process-kill process 15))
      (ignore-errors (sb-ext:process-close process)))
    (ignore-errors (wayland.server:close-display display))))

;;; ---------------------------------------------------------------------------
;;; The manual demo's mode: --follow-pointer
;;;
;;; scripts/popup-demo.sh launches the same client with --follow-pointer, so the menu
;;; appears where it was clicked instead of at one of the two fixed anchors.  That is
;;; a different code path in the client (a 1x1 anchor rectangle at the pointer), and
;;; it is the one a person sees, so it is checked here rather than trusted.
;;; ---------------------------------------------------------------------------

(let* ((client (or (uiop:getenv "POPUP_CLIENT")
                   (error "POPUP_CLIENT is not set")))
       (compositor (cf:make-headless-compositor :width 320 :height 240
                                                :background *background*))
       (display (cf:compositor-display compositor))
       (process nil))
  (unwind-protect
       (progn
         (format t "~%with --follow-pointer (the demo's mode)~%")
         (setf process (sb-ext:run-program client (list "--follow-pointer")
                                           :wait nil :output t :error t))
         (check (pump-until compositor
                            (lambda ()
                              (let ((toplevel (first (resources-of-type
                                                      compositor
                                                      'wayland.server:xdg-toplevel))))
                                (and toplevel (wayland.server:xdg-toplevel-mapped-p toplevel))))
                            20)
                "the follow-pointer client's window mapped")
         (pump compositor 0.2)
         ;; Well away from every corner, so nothing about this depends on the output's
         ;; edges: the menu must land on the click.
         (click compositor 77 63)
         (let ((popup (pump-until compositor
                                  (lambda ()
                                    (let ((popup (first (live-popups compositor))))
                                      (and popup (wayland.server:xdg-popup-geometry popup)
                                           popup)))
                                  20)))
           (check popup "a click opened a menu")
           (when popup
             (check (equal '(78 64 120 80) (wayland.server:xdg-popup-geometry popup))
                    "the menu is anchored at the pointer: ~S, got ~S"
                    '(78 64 120 80) (wayland.server:xdg-popup-geometry popup))
             (pump compositor 0.2)
             ;; Away from the pointer, which draws its own cursor over the menu at
             ;; (77, 63): the point here is the *popup's* pixels, not the arrow's.
             (check (= *popup-colour* (cf:frame-pixel compositor 150 100))
                    "its pixels are drawn at the click's menu (150, 100)")
             (cf:inject-key compositor "Escape" :pressed)
             (cf:inject-key compositor "Escape" :released)
             (check (pump-until compositor
                                (lambda () (wayland.server:xdg-popup-dismissed-p popup))
                                10)
                    "Escape dismissed it")
             (pump compositor 0.2)
             (check (= *window-colour* (cf:frame-pixel compositor 150 100))
                    "and the window is whole again")))
         (check (sb-ext:process-alive-p process) "the client is still connected"))
    (when process
      (ignore-errors (sb-ext:process-kill process 15))
      (ignore-errors (sb-ext:process-close process)))
    (ignore-errors (wayland.server:close-display display))))

(format t "~%popup-gate: ~D failure~:P~%" *failures*)
(uiop:quit (if (zerop *failures*) 0 1))

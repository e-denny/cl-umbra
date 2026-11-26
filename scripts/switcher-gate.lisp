;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The switcher gate (clause 20): a visible Alt+Tab overlay over three real
;;;; clients, read back pixel by pixel.
;;;;
;;;; Run by scripts/switcher-gate.sh.  The environment carries WESTON_CLIENT (a
;;;; system binary, run three times with a title each) and SWITCHER_LOG_DIR.
;;;;
;;;; Why a tinywl compositor and not a bare headless one: the point of the slice is
;;;; that Alt+Tab shows what it is choosing, and Alt+Tab is cl-tinywl's binding
;;;; (D51).  Driving the port's own keymap is what makes this a test of the thing a
;;;; person will use rather than of a function.
;;;;
;;;; What is asserted, and why each assertion is a real one:
;;;;
;;;;   * opening paints an overlay above three real windows, and the frame that
;;;;     holds it repaints the whole output     -- the draw list changed order, and
;;;;     the damage diff says so (D48);
;;;;   * the panel, the outline and the selection bar are where the layout says, in
;;;;     the colours the switcher says          -- a frame that is not drawn is not
;;;;     a switcher;
;;;;   * each row's text is *that window's own title*, found by measuring the pixels
;;;;     of the last glyph: only the title produces that width, and only the focus
;;;;     stack puts that title in that row (D45, D51);
;;;;   * Tab moves the bar and damages two rows rather than the output -- a
;;;;     selection move must not be a full repaint;
;;;;   * releasing Alt focuses and raises the row that was showing, and the frame
;;;;     afterwards is byte-identical to a full repaint -- the overlay left nothing
;;;;     behind;
;;;;   * Escape and a click cancel without moving the focus, and one backwards step
;;;;     (Alt+Shift+Tab) opens on the window that has the keys now;
;;;;   * the overlay is never hit-tested: a point inside the panel finds the window
;;;;     under it, or nothing -- never the panel.
;;;;
;;;; The pointer is parked in the top-left corner for the pixel checks: the cursor
;;;; is composited last (D31), and an arrow in the middle of a title would be
;;;; evidence of nothing.

(asdf:load-system "cl-tinywl")

(in-package #:cl-user)

(defparameter *scale* 2
  "The output's scale.  Text at scale 2 is drawn at twice the size rather than
upscaled, and it is the case a person on a HiDPI screen actually sees -- which is
also the case where a mistake is visible.")

(defvar *compositor* nil)
(defvar *failures* 0)

(defun check (value control &rest arguments)
  (if value
      (format t "  ok   ~?~%" control arguments)
      (progn (incf *failures*)
             (format t "  FAIL ~?~%" control arguments)))
  value)

(defun pump (seconds)
  (let ((deadline (+ (get-internal-real-time)
                     (* seconds internal-time-units-per-second)))
        (display (cf:compositor-display *compositor*)))
    (loop until (> (get-internal-real-time) deadline)
          do (wayland.server:run-once display :timeout 0.01))))

(defun pump-until (predicate seconds)
  (let ((deadline (+ (get-internal-real-time)
                     (* seconds internal-time-units-per-second)))
        (display (cf:compositor-display *compositor*)))
    (loop
      (let ((value (funcall predicate)))
        (when value (return value))
        (when (> (get-internal-real-time) deadline) (return nil))
        (wayland.server:run-once display :timeout 0.01)))))

(defun frame ()
  "Draw a frame now and return it, so a pixel is never from the frame before."
  (cf:render-frame *compositor*)
  (cf:frame-octets *compositor*))

(defun pixel-at (octets x y)
  "The 0xAARRGGBB pixel at device (X, Y) of OCTETS, which is BGRA in memory."
  (let ((offset (* 4 (+ x (* y (cf:compositor-device-width *compositor*))))))
    (logior (aref octets offset)
            (ash (aref octets (+ offset 1)) 8)
            (ash (aref octets (+ offset 2)) 16)
            (ash (aref octets (+ offset 3)) 24))))

(defun text-extent (octets x0 y0 width height)
  "The leftmost and rightmost x of the text colour in a device box, and how many.

Searched inside the panel only: a client's own pixels are not the switcher's, and a
window that happens to contain the text colour must not be able to vote."
  (let ((leftmost nil)
        (rightmost nil)
        (count 0))
    (loop for y from y0 below (+ y0 height)
          do (loop for x from x0 below (+ x0 width)
                   when (= cf.switcher:+switcher-text-colour+ (pixel-at octets x y))
                     do (setf leftmost (if leftmost (min leftmost x) x)
                              rightmost (if rightmost (max rightmost x) x))
                        (incf count)))
    (values leftmost rightmost count)))

(defun mapped-count ()
  (length (remove-if-not (lambda (surface)
                           (and (wayland.server:surface-mapped-p surface)
                                (wayland.server:surface-current-buffer surface)))
                         (cf:compositor-surfaces *compositor*))))

(defun focused-surface ()
  (wayland.server:seat-keyboard-focus (cf:compositor-seat *compositor*)))

(defun frontmost-window-surface ()
  "The surface of the topmost child of the scene's root, or NIL."
  (let* ((root (cf.scene:scene-root (cf:compositor-scene *compositor*)))
         (node (car (last (cf.scene:node-children root)))))
    (and (typep node 'cf.scene:buffer-node)
         (cf.scene:buffer-node-surface node))))

(defun overlay-children ()
  (cf.scene:node-children (cf.scene:scene-overlay (cf:compositor-scene *compositor*))))

(defun switcher ()
  (cf:compositor-switcher *compositor*))

(defun switcher-open-p ()
  (let ((switcher (switcher)))
    (and switcher (cf.switcher:switcher-open-p switcher))))

(defun stack-titles ()
  (mapcar #'cf:window-title (cf:compositor-focus-stack *compositor*)))

(defun press (key)
  (cf:inject-key *compositor* key :pressed))

(defun release (key)
  (cf:inject-key *compositor* key :released))

(defun tap (key)
  (press key)
  (release key))

(defun open-switcher ()
  "Alt down, Tab tapped: the overlay is up and the first row is selected."
  (press "Alt_L")
  (tap "Tab"))

(defun close-switcher ()
  (tap "Escape")
  (release "Alt_L"))

;;; ---------------------------------------------------------------------------
;;; The same overlay, one compositor deeper
;;; ---------------------------------------------------------------------------
;;;
;;; A nested session is the way a person actually looks at this: the switcher is
;;; drawn into the inner compositor's buffer and the *parent* composites it.  That
;;; is worth a check of its own because the two compositors disagree about scale on
;;; purpose -- the inner one draws at 2 device pixels per layout pixel, the parent
;;; here is a scale-1 output showing that buffer shrunk back to layout -- so "the
;;; pixels arrived" only means something at the coordinate the mapping implies
;;; (D49).  And the overlay is the one thing in this session that is not a window,
;;; so it is the thing most likely to be dropped by a presenter that only knows
;;; about clients.

(defun pump-world (parent nested seconds)
  (let ((deadline (+ (get-internal-real-time)
                     (* seconds internal-time-units-per-second))))
    (loop while (< (get-internal-real-time) deadline)
          do (cf:nested-dispatch nested :timeout 0)
             (wayland.server:run-once (cf:compositor-display parent) :timeout 0.005))))

(defun the-nested-half (client)
  (let* ((directory (uiop:getenv "XDG_RUNTIME_DIR"))
         (parent (cf:make-headless-compositor :width 400 :height 300
                                              :display-name "sw-parent"
                                              :runtime-dir directory))
         (parent-display (cf:compositor-display parent))
         (session nil))
    (unwind-protect
         (progn
           (setf session
                 (tinywl:start :mode :nested :width 400 :height 300 :scale *scale*
                               :parent-path (wayland.server:display-socket-path
                                             parent-display)
                               :display-name "sw-child" :runtime-dir directory
                               :pump (lambda (seconds)
                                       (wayland.server:run-once parent-display
                                                                :timeout seconds))))
           (let ((inner (tinywl:session-compositor session))
                 (nested (tinywl:session-nested session)))
             (pump-world parent nested 1.0)
             (check (cf:nested-mapped-p nested)
                    "the parent mapped the nested session's window")
             (tinywl:launch inner :command (list client "--title=DELTA"))
             (pump-world parent nested 1.5)
             (tinywl:launch inner :command (list client "--title=EPSILON"))
             (pump-world parent nested 2.0)
             (let ((windows (remove-if-not
                             (lambda (surface)
                               (and (wayland.server:surface-mapped-p surface)
                                    (wayland.server:surface-current-buffer surface)))
                             (cf:compositor-surfaces inner))))
               (check (= 2 (length windows))
                      "two clients mapped inside it (~D)" (length windows)))
             (cf:inject-key inner "Alt_L" :pressed)
             (cf:inject-key inner "Tab" :pressed)
             (check (let ((switcher (cf:compositor-switcher inner)))
                      (and switcher (cf.switcher:switcher-open-p switcher)))
                    "Alt+Tab opened the switcher inside the nested session")
             (pump-world parent nested 1.0)
             (let* ((layout (cf.switcher:switcher-layout
                             (cf:compositor-switcher inner)))
                    ;; A point just inside the panel's top-left corner, in the inner
                    ;; compositor's device pixels.
                    (x (* *scale* (+ (getf layout :x) 3)))
                    (y (* *scale* (+ (getf layout :y) 3))))
               (check (= cf.switcher:+switcher-panel-colour+
                         (cf:frame-pixel-device inner x y))
                      "the nested compositor drew the panel into its own frame")
               ;; Inner device -> inner layout -> parent device: the parent is a
               ;; scale-1 output showing a buffer that says buffer_scale 2.
               (check (= cf.switcher:+switcher-panel-colour+
                         (cf:frame-pixel-device parent (floor x *scale*)
                                                (floor y *scale*)))
                      "and the parent's own frame has it at the mapped point"))
             (cf:inject-key inner "Alt_L" :released)
             (pump-world parent nested 0.5)
             (check (null (cf:compositor-switcher inner))
                    "releasing Alt closed it inside the nested session")
             (check (null (cf.scene:node-children
                           (cf.scene:scene-overlay (cf:compositor-scene inner))))
                    "and left no overlay nodes behind"))
      (when session (ignore-errors (tinywl:stop session)))
      (ignore-errors (wayland.server:close-display parent-display))))))

(let* ((client (or (uiop:getenv "WESTON_CLIENT")
                   (error "WESTON_CLIENT is not set")))
       (log-dir (uiop:getenv "SWITCHER_LOG_DIR"))
       (processes '()))
  (flet ((start-client (label)
           (let* ((log (format nil "~A/~A.log" (or log-dir "/tmp") label))
                  ;; One file for both streams: two opens of one path would race.
                  (process (sb-ext:run-program client (list (format nil "--title=~A" label))
                                               :wait nil :output log :error :output)))
             (push process processes)
             (format t "client ~A: pid ~D, log ~A~%" label
                     (sb-ext:process-pid process) log)
             process)))
    (unwind-protect
         (progn
           (setf *compositor* (tinywl:make-tinywl :width 800 :height 600 :scale *scale*))
           (format t "compositor: 800x600 at scale ~D, socket ~A~%"
                   *scale* (wayland.server:display-socket-path
                            (cf:compositor-display *compositor*)))
           ;; Out of the way before anything is drawn: the arrow is composited last.
           (cf:inject-pointer-motion *compositor* 0 0)

           ;; 1. Three windows, mapped in order, so the stack's tail is the first.
           (loop for label in '("ALPHA" "BETA" "GAMMA")
                 for count from 1
                 do (start-client label)
                    (check (pump-until (lambda () (= count (mapped-count))) 20)
                           "window ~A mapped" label))
           (pump 0.5)
           (check (equal '("GAMMA" "BETA" "ALPHA") (stack-titles))
                  "the stack is ~S, most recently focused first" (stack-titles))
           (check (equal "GAMMA" (cf:window-title (focused-surface)))
                  "and the last window to map has the keyboard")

           ;; A baseline of the desktop with no overlay, for the comparisons below.
           (cf:invalidate-output *compositor*)
           (let ((desktop (frame))
                 (desktop-damage (cf:output-damage-bounds *compositor*)))
             (check (eq :full desktop-damage)
                    "the first frame repainted the whole output")

             ;; 2. Alt+Tab: the overlay opens, listing the stack from its tail.
             (press "Alt_L")
             (check (eq t (press "Tab")) "the Tab press was consumed")
             (check (switcher-open-p) "and the switcher is open")
             (check (equal '("ALPHA" "BETA" "GAMMA")
                           (cf.switcher:switcher-titles (switcher)))
                    "listing the focus stack from its tail, one row per client")
             (check (zerop (cf.switcher:switcher-index (switcher)))
                    "with the first row selected")
             (let* ((layout (cf.switcher:switcher-layout (switcher)))
                    (x (getf layout :x))
                    (y (getf layout :y))
                    (width (getf layout :width))
                    (height (getf layout :height))
                    (padding (getf layout :padding))
                    (rows (getf layout :rows))
                    (texts (getf layout :texts))
                    (text-x (getf layout :text-x))
                    (output (frame)))
               (check (eq :full (cf:output-damage-bounds *compositor*))
                      "opening it changed the stacking order, so the frame was full")
               (check (not (equalp desktop output))
                      "and the frame is not the desktop any more")
               ;; A point just inside the panel's top-left corner: inside the panel,
               ;; above the first row's bar.
               (check (= cf.switcher:+switcher-panel-colour+
                         (pixel-at output (* *scale* (+ x 3)) (* *scale* (+ y 3))))
                      "the panel is drawn where the layout puts it, in its colour")
               (check (= cf.switcher:+switcher-border-colour+
                         (pixel-at output (* *scale* (1- x)) (* *scale* (+ y 3))))
                      "with a one-pixel outline around it")
               ;; The bar spans the panel's inner width on the selected row, so a
               ;; point three pixels inside the right edge is the bar on that row and
               ;; the panel on any other.
               (flet ((row-pixel (row octets)
                        (pixel-at octets
                                  (* *scale* (- (+ x width) 3))
                                  (* *scale* (+ (nth row rows) 2)))))
                 (dotimes (row 3)
                   (check (= (if (zerop row)
                                 cf.switcher:+switcher-highlight-colour+
                                 cf.switcher:+switcher-panel-colour+)
                             (row-pixel row output))
                          "row ~D is ~:[the panel~;the selection bar~]" row (zerop row)))
                 ;; 3. Each row's text is that client's title at the output's scale.
                 ;;    Every title ends in A, whose rightmost column is lit, so the
                 ;;    right-hand end of the text is a width only the title produces.
                 (loop for title in texts
                       for row in rows
                       for index from 0
                       do (multiple-value-bind (left right count)
                              (text-extent output
                                           (* *scale* (+ x 2)) (* *scale* row)
                                           (* *scale* (- width 4)) (* *scale* 7))
                            (let ((start (* *scale* text-x))
                                  (expected-end (1- (+ (* *scale* text-x)
                                                       (* *scale* (cf.font:text-width title))))))
                              (check (and count (= right expected-end))
                                     "row ~D draws ~S: ~D device pixels wide, ending at ~D"
                                     index title
                                     (if count (1+ (- right start)) 0) right)
                              (check (and left (< (- left start) (* *scale* 5)))
                                     "row ~D starts at the panel's text column" index))))

                 ;; 4. Tab moves the bar, and damages two rows rather than the frame.
                 (tap "Tab")
                 (check (= 1 (cf.switcher:switcher-index (switcher)))
                        "Tab moved the selection to the second row")
                 (let ((after (frame)))
                   (check (= cf.switcher:+switcher-panel-colour+ (row-pixel 0 after))
                          "the first row is no longer selected")
                   (check (= cf.switcher:+switcher-highlight-colour+ (row-pixel 1 after))
                          "the second is")
                   (let ((bounds (cf:output-damage-bounds *compositor*)))
                     (check (and (listp bounds) (< (fourth bounds) (* *scale* height)))
                            "and the frame damaged ~S -- two rows, not the output"
                            bounds)))
                 ;; 5. Two more steps wrap back to the first row.
                 (tap "Tab")
                 (check (= 2 (cf.switcher:switcher-index (switcher))) "then the third row")
                 (tap "Tab")
                 (check (zerop (cf.switcher:switcher-index (switcher)))
                        "and a step past the last row wraps to the first"))

                 ;; 6. Releasing Alt takes the row that was showing.
                 (release "Alt_L")
                 (check (null (switcher)) "releasing Alt closed the switcher")
                 (check (null (overlay-children)) "and took every overlay node with it")
                 (check (equal "ALPHA" (cf:window-title (focused-surface)))
                        "the first row -- ALPHA -- has the keyboard")
                 (check (equal "ALPHA" (cf:window-title (frontmost-window-surface)))
                        "and was raised: the choice is visible in the scene")
                 (check (equal '("ALPHA" "GAMMA" "BETA") (stack-titles))
                        "and the history rotated, exactly as one tap of Tab always did")
                 (let ((committed (frame)))
                   (check (eq :full (cf:output-damage-bounds *compositor*))
                          "the overlay going away is a stacking change, so a full frame")
                   (cf:invalidate-output *compositor*)
                   (check (equalp committed (frame))
                          "and the frame it left is byte-identical to a full repaint")))

             ;; 7. Escape cancels; the focus does not move.
             (let ((before (focused-surface)))
               (open-switcher)
               (check (switcher-open-p) "Alt+Tab opened it again")
               (check (eq t (press "Escape"))
                      "Escape was consumed (Alt is down, and Alt+Escape quits)")
               (check (null (switcher)) "and cancelled the switcher")
               (check (eq before (focused-surface)) "without moving the keyboard")
               (check (null (overlay-children)) "and without leaving an overlay behind")
               (release "Alt_L"))

             ;; 8. A click cancels it too, and is then delivered as a click.
             (open-switcher)
             (check (switcher-open-p) "Alt+Tab opened it a third time")
             (cf:inject-pointer-button *compositor* :left :pressed)
             (check (null (switcher)) "a pointer press cancelled it")
             (check (null (overlay-children)) "and the overlay is gone")
             (cf:inject-pointer-button *compositor* :left :released)
             (release "Alt_L")

             ;; 9. The overlay is never hit-tested: a point inside the panel belongs
             ;;    to whatever is under it, and never to the panel.
             (open-switcher)
             (let* ((layout (cf.switcher:switcher-layout (switcher)))
                    (hit (cf.scene:scene-hit-test (cf:compositor-scene *compositor*)
                                                  (getf layout :x)
                                                  (getf layout :y))))
               (check (or (null hit) (typep hit 'cf.scene:buffer-node))
                      "a point inside the panel hits the window under it, never the overlay"))
             (release "Alt_L")
             (check (null (switcher)) "releasing Alt committed the row that was showing"))

           ;; 10. One step backwards opens on the window that has the keys now.
           (let ((before (focused-surface)))
             (press "Alt_L")
             (press "Shift_L")
             (tap "Tab")
             (check (switcher-open-p) "Alt+Shift+Tab opened the switcher")
             (check (= 2 (cf.switcher:switcher-index (switcher)))
                    "on the last row, which is the window that has the keys")
             (check (eq before (cf.switcher:switcher-selected (switcher)))
                    "with no step taken past it")
             (release "Shift_L")
             (release "Alt_L")
             (check (eq before (focused-surface))
                    "and committing that row leaves the focus where it was"))

           ;; 11. The same overlay, one compositor deeper.
           (the-nested-half client)

           ;; 12. The clients survived all of it.
           (check (every (lambda (process) (sb-ext:process-alive-p process)) processes)
                  "all three clients are still connected"))
      (when *compositor*
        (dolist (process processes)
          (when process
            (ignore-errors (sb-ext:process-kill process 15))
            (ignore-errors (sb-ext:process-close process))))
        (ignore-errors (wayland.server:close-display
                        (cf:compositor-display *compositor*)))))))

(format t "~%switcher-gate: ~D failure~:P~%" *failures*)
(uiop:quit (if (zerop *failures*) 0 1))

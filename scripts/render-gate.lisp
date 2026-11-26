;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The phase-2b gate: buffer scale, buffer transform, damage and opaque culling.
;;;;
;;;; Run by scripts/render-gate.sh, which compiles the client first.  The environment
;;;; carries RENDER_CLIENT (the binary), FRAME_PNG and the usual WAYLAND_DISPLAY /
;;;; XDG_RUNTIME_DIR.
;;;;
;;;; Two halves, and they prove different things.  The client half is a real
;;;; libwayland peer deciding its own buffer scale and transform: the quadrants it
;;;; drew must land where those two numbers say, at scale 1 and at scale 2, which is
;;;; the whole of "a HiDPI session draws at 1:1".  The scene half has no client at
;;;; all: it moves rectangles a few pixels at a time and insists that what the
;;;; incremental painter produced is what a full repaint would have produced -- the
;;;; invariant that makes damage tracking safe (D48, D49, D50).

;; The source registry and Quicklisp are set up by scripts/lib.sh, which the driver
;; has already sourced.
(asdf:load-system "cl-compositor-framework")

(in-package #:cl-user)

;; Premultiplied, opaque: the four quadrants the client draws.
(defparameter *red* #xFFFF0000)
(defparameter *green* #xFF00FF00)
(defparameter *blue* #xFF0000FF)
(defparameter *white* #xFFFFFFFF)
(defparameter *background* #xFF000000)

(defparameter *failures* 0)
(defparameter *compositor* nil)
(defparameter *directory* nil)
(defparameter *client* nil)

(defun check (pixels)
  "PIXELS is a list of (X Y EXPECTED DESCRIPTION); count and report failures."
  (dolist (entry pixels)
    (destructuring-bind (x y expected description) entry
      (let ((actual (cf:frame-pixel-device *compositor* x y)))
        (cond ((= actual expected)
               (format t "  ok   ~A: (~D,~D) = #x~8,'0X~%" description x y actual))
              (t
               (incf *failures*)
               (format t "  FAIL ~A: (~D,~D) = #x~8,'0X, expected #x~8,'0X~%"
                       description x y actual expected)))))))

(defun check-that (predicate description &rest arguments)
  "One assertion about the frame, for the cases a single expected word cannot say."
  (if (apply predicate arguments)
      (format t "  ok   ~A~%" (apply #'format nil description arguments))
      (progn
        (incf *failures*)
        (format t "  FAIL ~A~%" (apply #'format nil description arguments)))))

(defun pump-for (seconds)
  (let ((deadline (+ (get-internal-real-time)
                     (* seconds internal-time-units-per-second)))
        (display (cf:compositor-display *compositor*)))
    (loop until (> (get-internal-real-time) deadline)
          do (wayland.server:run-once display :timeout 0.01))))

(defun run-client (&rest arguments)
  "Run the scale client to completion inside the current compositor.

Returns true when it exited 0, which it only does after its frame callback -- so a
passing run means the frame was composited and presented, not merely accepted."
  (let* ((process (sb-ext:run-program *client* arguments
                                      :wait nil :output t :error t))
         (status nil)
         (deadline (+ (get-internal-real-time) (* 30 internal-time-units-per-second))))
    (loop
      (when (not (sb-ext:process-alive-p process))
        (setf status (sb-ext:process-exit-code process))
        (return))
      (when (> (get-internal-real-time) deadline)
        (sb-ext:process-kill process 15)
        (return))
      (wayland.server:run-once (cf:compositor-display *compositor*) :timeout 0.01))
    (pump-for 0.2)
    (and status (zerop status))))

(defmacro with-output ((width height scale) &body body)
  "A fresh compositor of the given layout size and output scale, for BODY."
  `(let ((*compositor*
           (cf:make-headless-compositor
            :width ,width :height ,height :scale ,scale
            ;; The client connects through WAYLAND_DISPLAY, so each compositor in
            ;; turn takes the name the environment already has; the previous one is
            ;; closed before the next is made.
            :display-name "wayland-0"
            :runtime-dir *directory*
            :background *background*)))
     ;; The pointer is composited last and would sit exactly where these checks
     ;; read; the cursor has its own check below, where it is turned back on.
     (setf (cf:compositor-cursor-visible-p *compositor*) nil)
     (unwind-protect (locally ,@body)
       (wayland.server:close-display (cf:compositor-display *compositor*)))))

(defun check-quadrants (device-width device-height)
  "The four quadrants of the client's buffer, at the device size they occupy.

The samples sit a quarter of a quadrant inside each corner, so they say nothing
about the exact edge -- which is the next pixel's business -- and everything about
which quadrant went where."
  (let ((mid-x (floor device-width 2))
        (mid-y (floor device-height 2))
        (inset 4))
    (check (list (list inset inset *red* "top-left is red")
                 (list (+ mid-x inset) inset *green* "top-right is green")
                 (list inset (+ mid-y inset) *blue* "bottom-left is blue")
                 (list (+ mid-x inset) (+ mid-y inset) *white* "bottom-right is white")))))

(defun device-pixel-count ()
  "How many pixels of the frame are not the background: one number for 'was it drawn'."
  (let ((octets (cf:frame-octets *compositor*))
        (count 0))
    (loop for index from 0 below (length octets) by 4
          unless (and (= (aref octets index) 0)
                      (= (aref octets (+ index 1)) 0)
                      (= (aref octets (+ index 2)) 0)
                      (= (aref octets (+ index 3)) #xFF))
            do (incf count))
    count))

;;; ---------------------------------------------------------------------------
;;; The client half: scale and transform
;;; ---------------------------------------------------------------------------

(defun the-client-half ()
  (format t "~%1. a 64x32 buffer at buffer scale 1 on a scale-1 output~%")
  (with-output (200 200 1)
    (check-that #'identity "the client presented a frame" (run-client "--attach" "0,0"))
    (check-quadrants 64 32)
    (check-that (lambda (count) (= count (* 64 32))) "~D device pixels drawn"
                (device-pixel-count)))

  (format t "~%2. the same buffer on a scale-2 output: magnified to 128x64~%")
  (with-output (200 200 2)
    (check-that #'identity "the client presented a frame" (run-client "--attach" "0,0"))
    (check-quadrants 128 64)
    (check (list (list 127 63 *white* "the far device corner is the buffer's last pixel")
                 (list 128 8 *background* "and one pixel past it is background"))))

  (format t "~%3. a buffer scale-2 client on a scale-2 output: 1:1, not upscaled~%")
  (with-output (200 200 2)
    (check-that #'identity "the client presented a frame"
                (run-client "--scale" "2" "--attach" "0,0"))
    ;; 64x32 at buffer scale 2 is a 32x16 surface, which is 64x32 device pixels.
    (check-quadrants 64 32)
    (check (list (list 63 31 *white* "the surface ends where its buffer does")
                 (list 64 8 *background* "and the layout is 32x16, so 64 is past it"))))

  (format t "~%4. transform 90 (counter-clockwise): the right column becomes the top row~%")
  (with-output (200 200 1)
    (check-that #'identity "the client presented a frame"
                (run-client "--transform" "1" "--attach" "0,0"))
    ;; Drawn 32x64: dest(dx,dy) = src(63 - dy, dx), so the buffer's quadrants come
    ;; out as green, white over red, blue -- turned a quarter turn anticlockwise.
    (check (list (list 4 4 *green* "top-left is the buffer's top-right")
                 (list 28 4 *white* "top-right is the buffer's bottom-right")
                 (list 4 60 *red* "bottom-left is the buffer's top-left")
                 (list 28 60 *blue* "bottom-right is the buffer's bottom-left")
                 (list 32 8 *background* "and it is 32 wide, not 64"))))

  (format t "~%5. transform 180 turns the buffer end for end~%")
  (with-output (200 200 1)
    (check-that #'identity "the client presented a frame"
                (run-client "--transform" "2" "--attach" "0,0"))
    (check (list (list 4 4 *white* "top-left is the buffer's bottom-right")
                 (list 60 4 *blue* "top-right is the buffer's bottom-left")
                 (list 4 28 *green* "bottom-left is the buffer's top-right")
                 (list 60 28 *red* "bottom-right is the buffer's top-left")))))

;;; ---------------------------------------------------------------------------
;;; The scene half: damage, and opaque culling that cannot be seen
;;; ---------------------------------------------------------------------------

(defun brushed-p (pixel)
  "A blended veil over the green background: lighter than the green, not white."
  (and (> (ldb (byte 8 16) pixel) #x00)          ; some red
       (> (ldb (byte 8 0) pixel) #x00)           ; some blue
       (< (ldb (byte 8 16) pixel) #xFF)          ; but not opaque white
       (= #xFF (ldb (byte 8 24) pixel))))

(defun the-damage-half (png)
  (format t "~%6. damage: an incremental frame equals a full one~%")
  (with-output (120 90 1)
    (let ((scene (cf:compositor-scene *compositor*))
          (moves '()))
      (setf (cf:compositor-cursor-visible-p *compositor*) nil)
      ;; An opaque background rectangle, an opaque window over it, and a
      ;; translucent veil over both: culling has something to hide, and blending
      ;; has something to blend.
      (cf.scene:scene-add-node scene (cf.scene:make-rect-node 100 70 #xFF00FF00) :x 10 :y 10)
      (let ((window (cf.scene:scene-add-node scene (cf.scene:make-rect-node 40 30 #xFF0000FF)
                                            :x 20 :y 20))
            (veil (cf.scene:scene-add-node scene (cf.scene:make-rect-node 20 20 #x80808080)
                                          :x 70 :y 50)))
        (cf:render-frame *compositor*)
        (if (eq :full (cf:output-damage-bounds *compositor*))
            (format t "  ok   the first frame repainted the whole output~%")
            (progn (incf *failures*)
                   (format t "  FAIL the first frame was not a full repaint~%")))
        (check (list (list 30 30 *blue* "the opaque window covers the background")
                     (list 12 12 *green* "and the background is drawn around it")))
        (let ((veil-pixel (cf:frame-pixel-device *compositor* 75 55)))
          (check-that #'brushed-p
                      (format nil "the translucent veil blends over the green at (75,55): #x~8,'0X"
                              veil-pixel)
                      veil-pixel))
        (dolist (step '((5 0) (0 7) (-3 -2) (9 4) (-6 3)))
          (incf (cf.scene:node-x window) (first step))
          (incf (cf.scene:node-y window) (second step))
          (incf (cf.scene:node-x veil) (- (first step)))
          (cf:render-frame *compositor*)
          (push (cf:output-damage-bounds *compositor*) moves))
        (let ((bounds (first moves)))
          (if (and bounds (< (third bounds) 120) (< (fourth bounds) 90))
              (format t "  ok   the last frame repainted ~Dx~D of 120x90, not all of it~%"
                      (third bounds) (fourth bounds))
              (progn
                (incf *failures*)
                (format t "  FAIL the last frame repainted ~S, so damage did nothing~%"
                        bounds)))
          (let ((partial (cf:compositor-partial-frame-count *compositor*)))
            (if (plusp partial)
                (format t "  ok   ~D of the frames were partial~%" partial)
                (progn (incf *failures*)
                       (format t "  FAIL no frame was partial~%")))))
        (let ((incremental (cf:frame-octets *compositor*)))
          (cf:invalidate-output *compositor*)
          (cf:render-frame *compositor*)
          (if (equalp incremental (cf:frame-octets *compositor*))
              (format t "  ok   the incremental frame and a full repaint are identical~%")
              (progn (incf *failures*)
                     (format t "  FAIL the incremental frame differs from a full repaint~%")))
          (if (eq :full (cf:output-damage-bounds *compositor*))
              (format t "  ok   and invalidate-output did repaint the whole output~%")
              (progn (incf *failures*)
                     (format t "  FAIL invalidate-output left the damage partial~%"))))
        (cf:write-frame-png *compositor* png)))))

(defun the-cursor-half ()
  (format t "~%7. the pointer on a scale-2 output is drawn at twice its size~%")
  (with-output (64 64 2)
    (progn
      (cf:inject-pointer-motion *compositor* 5 5)
      (setf (cf:compositor-cursor-visible-p *compositor*) t)
      ;; The arrow's (1,3) pixel is white; at scale 2 it covers the 2x2 block at
      ;; device (12,16).  A 16x16 cursor would have its body at (6,8) instead, so
      ;; this is the difference between a cursor that scales and one that does not.
      (cf:render-frame *compositor*)
      (check (list (list 12 16 *white* "the arrow's body is white at device (12,16)")
                   (list 0 0 *background* "the tip's own pixel is the outline, not white")
                   (list 5 5 #xFF000000 "and the tip is where the logical pointer is"))))))

;;; ---------------------------------------------------------------------------
;;; A nested session at scale 2: the parent is told, and asked for a buffer twice
;;; the size.  This is the path a HiDPI nested session takes on the way out.
;;; ---------------------------------------------------------------------------

(defun the-nested-half ()
  (format t "~%8. a nested session at scale 2 tells its parent, and gets its pixels 1:1~%")
  (let* ((parent (cf:make-headless-compositor
                  :width 300 :height 200 :display-name "wayland-0"
                  :runtime-dir *directory*
                  ;; A background of its own, so the nested window is visible as a
                  ;; rectangle rather than as a coincidence of black.
                  :background #xFF224466))
         (parent-display (cf:compositor-display parent))
         (nested nil))
    (unwind-protect
         (progn
           (setf nested (cf:start-nested
                         :parent-path (wayland.server:display-socket-path parent-display)
                         :width 100 :height 80 :scale 2
                         :display-name "render-nested"
                         :runtime-dir *directory*
                         :pump (lambda (timeout)
                                 (wayland.server:run-once parent-display :timeout timeout))))
           (let ((deadline (+ (get-internal-real-time)
                              (* 10 internal-time-units-per-second))))
             (loop until (or (plusp (cf:nested-frame-count nested))
                             (> (get-internal-real-time) deadline))
                   do (cf:nested-dispatch nested :timeout 0)
                      (wayland.server:run-once parent-display :timeout 0.005)))
           (if (plusp (cf:nested-frame-count nested))
               (format t "  ok   the nested session presented ~D frame~:P~%"
                       (cf:nested-frame-count nested))
               (progn (incf *failures*)
                      (format t "  FAIL the nested session never presented a frame~%")))
           ;; The parent's server records what the nested session said about its
           ;; buffer: scale 2, and a buffer twice the layout size it was configured at.
           (let* ((surfaces (cf:compositor-surfaces parent))
                  (window (find-if (lambda (surface)
                                     (and (wayland.server:surface-current-buffer surface)
                                          (plusp (wayland.server:surface-buffer-scale surface))))
                                   surfaces)))
             (if window
                 (format t "  ok   the parent saw a surface asking for buffer scale ~D~%"
                         (wayland.server:surface-buffer-scale window))
                 (progn (incf *failures*)
                        (format t "  FAIL no surface of the parent asked for a buffer scale~%")))
             (when window
               (let ((buffer (wayland.server:surface-current-buffer window)))
                 (if (and (= 200 (wayland.server:shm-buffer-width buffer))
                          (= 160 (wayland.server:shm-buffer-height buffer)))
                     (format t "  ok   and its buffer is ~Dx~D for a 100x80 layout~%"
                             (wayland.server:shm-buffer-width buffer)
                             (wayland.server:shm-buffer-height buffer))
                     (progn
                       (incf *failures*)
                       (format t "  FAIL its buffer is ~Dx~D, not 200x160~%"
                               (wayland.server:shm-buffer-width buffer)
                               (wayland.server:shm-buffer-height buffer)))))))
           ;; And the parent draws that window at 100x80 layout pixels: inside is the
           ;; nested compositor's black, one pixel outside its edge is the parent's.
           (cf:render-frame parent)
           (let ((*compositor* parent))
             (check (list (list 50 40 #xFF000000 "the nested window's own background")
                          (list 100 40 #xFF224466 "and one pixel past its right edge")))))
      (when nested (ignore-errors (cf:stop-nested nested)))
      (wayland.server:close-display parent-display))))

;;; ---------------------------------------------------------------------------
;;; Run
;;; ---------------------------------------------------------------------------

(let ((client (or (uiop:getenv "RENDER_CLIENT")
                  (error "RENDER_CLIENT is not set")))
      (png (or (uiop:getenv "FRAME_PNG") "/tmp/cl-wayland-render.png"))
      (runtime-dir (uiop:getenv "XDG_RUNTIME_DIR")))
  (setf *client* client
        *directory* (or runtime-dir "/tmp"))
  (setf wayland.server:*log-level* :warn)
  (the-client-half)
  (the-damage-half png)
  (the-cursor-half)
  (the-nested-half)
  (format t "~&~:[FAILED~;PASSED~]: rendering~%" (zerop *failures*))
  (uiop:quit (if (zerop *failures*) 0 1)))

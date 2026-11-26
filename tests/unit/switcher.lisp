;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; Switcher tests: the font, the overlay, and the state machine (D51).
;;;;
;;;; Three levels, because three things can be wrong independently:
;;;;
;;;;   * the font -- one table, ninety-five glyphs, and arithmetic that a title's
;;;;     width and a raster's size both have to agree with;
;;;;   * the scene's overlay -- a second root drawn above the windows, below the
;;;;     cursor and findable by no hit test;
;;;;   * the switcher -- what it lists, what Tab and Shift+Tab do, what releasing
;;;;     Alt does, and what cancels it.
;;;;
;;;; The pixels are the gate's business (scripts/switcher-gate.lisp, clause 20):
;;;; the gate draws a real overlay over real clients and reads it back.  Here the
;;;; surfaces are made by hand, so a failing test names the rule that broke.

(in-package #:cl-user)

(defpackage #:wayland.test.switcher
  (:use #:cl #:rove)
  (:local-nicknames (#:scene #:cf.scene)
                    (#:sw #:cf.switcher)
                    (#:font #:cf.font)
                    (#:headless #:cf.backend.headless)
                    (#:input #:cf.input)
                    (#:srv #:wayland.server))  (:documentation
   "Tests for cf.font, the scene's overlay and cf.switcher (D51)."))

(in-package #:wayland.test.switcher)

;;; ---------------------------------------------------------------------------
;;; Fixtures
;;; ---------------------------------------------------------------------------

(defvar *directory-counter* 0)

(defun make-test-directory ()
  (let ((path (format nil "/tmp/cl-wayland-switcher-test-~D-~D/"
                      (get-universal-time) (incf *directory-counter*))))
    (ensure-directories-exist path)
    (wayland.ffi:chmod-path (string-right-trim "/" path) #o700)
    path))

(defmacro with-compositor ((compositor &key (width 320) (height 240) (scale 1)) &body body)
  "A headless compositor on a private socket and a quiet server."
  (let ((directory (gensym "DIRECTORY")))
    `(let ((,directory (make-test-directory))
           (srv:*log-level* :warn))
       (unwind-protect
            (let ((,compositor (cf:make-headless-compositor
                                :width ,width :height ,height :scale ,scale
                                :display-name "switcher-0"
                                :runtime-dir ,directory)))
              (unwind-protect (locally ,@body)
                (srv:close-display (cf:compositor-display ,compositor))))
         (uiop:delete-empty-directory ,directory)
         (ignore-errors (uiop:delete-directory-tree (pathname ,directory)
                                                    :validate t))))))

(defclass test-surface (cf:cf-surface) ()
  (:documentation
   "A surface whose keyboard focus is a bookkeeping change and nothing else.

The framework's method configures the client's toplevel on a focus change, and
these surfaces have no client: suppressing the configure here keeps the tests about
what the switcher does to the *stack*, not about what a socket would have received."))

(defmethod srv:seat-focus-changed ((seat srv:seat) (surface test-surface) has-focus)
  (declare (ignore seat has-focus))
  nil)

(defun fake-surface (&key (width 10) (height 10) mapped-p)
  "A wl_surface with a buffer of a known size and nothing else.

The scene only asks a surface for its buffer, its size, its scale, its transform
and its regions, and the protocol state machine has its own tests."
  (let ((surface (make-instance 'srv:surface
                                :client nil :id 9 :interface nil :version 1))
        (buffer (make-instance 'srv:shm-buffer
                               :pool nil :offset 0
                               :width width :height height
                               :stride (* 4 width) :format 0)))
    (when mapped-p
      (setf (srv:surface-current-buffer surface) buffer
            (srv:surface-mapped-p surface) t))
    surface))

(defun window (compositor &key title app-id (width 100) (height 80) (x 0) (y 0) buffer)
  "A mapped window surface with a toplevel role and a node at (X, Y).

The role object is real: WINDOW-TITLE reads the client's title from it, and a
window with no title and no app id is a case the switcher has to survive.  The
surface is a TEST-SURFACE, whose focus change sends nothing: there is no client on
the other end of these sockets, and a configure addressed to nobody is not the
topic here (gate clause 18 checks the activated state with real clients).

BUFFER is the buffer to attach, for a test that needs real pixels (PICTURE-BUFFER);
the default is a buffer with no pool behind it, which has a size and no picture --
the case a thumbnail has to survive.  Returns (values surface node)."
  (let* ((surface (make-instance 'test-surface
                                 :client nil :id 9 :interface nil :version 1))
         (shell (make-instance 'srv:xdg-surface
                               :client nil :id 11 :interface nil :version 1))
         (toplevel (make-instance 'srv:xdg-toplevel
                                  :client nil :id 12 :interface nil :version 1))
         (node (scene:scene-add-node (cf:compositor-scene compositor)
                                     (scene:make-buffer-node surface)
                                     :x x :y y)))
    (setf (srv:xdg-surface-role-name shell) :toplevel
          (srv:xdg-surface-role shell) toplevel
          (srv:xdg-toplevel-shell-surface toplevel) shell
          (srv:xdg-toplevel-title toplevel) title
          (srv:xdg-toplevel-app-id toplevel) app-id
          (srv:surface-shell-surface surface) shell
          (srv:surface-current-buffer surface)
          (or buffer
              (make-instance 'srv:shm-buffer :pool nil :offset 0
                                             :width width :height height
                                             :stride (* 4 width) :format 0))
          (srv:surface-mapped-p surface) t
          (cf:surface-scene-node surface) node)
    (values surface node)))

(defun picture-octets (width height left right)
  "WIDTH x HEIGHT ARGB8888 where the left half is one colour and the right half another.

Two flat colours rather than a photograph, so a downscale has an answer that can be
written down: bilinear filtering of a constant region is that constant, whatever the
ratio, so a thumbnail's left half is LEFT exactly and its right half is RIGHT
exactly -- which is a claim about scale, orientation and colour at once."
  (let ((octets (make-array (* 4 width height) :element-type '(unsigned-byte 8)))
        (half (floor width 2)))
    (dotimes (y height)
      (dotimes (x width)
        (let ((colour (if (< x half) left right))
              (offset (* 4 (+ x (* width y)))))
          (setf (aref octets offset) (ldb (byte 8 0) colour)
                (aref octets (+ offset 1)) (ldb (byte 8 8) colour)
                (aref octets (+ offset 2)) (ldb (byte 8 16) colour)
                (aref octets (+ offset 3)) (ldb (byte 8 24) colour)))))
    octets))

(defun picture-buffer (width height &key (left #xFFFF0000) (right #xFF0000FF))
  "A shm buffer with real pixels in a real mapping; four values.

(values BUFFER FD MAPPING SIZE).  A memfd, mapped read-only the way a pool maps it:
no socket, no client, and pixels the test can read back through the renderer.  The
caller unmaps MAPPING when it is done (nothing else owns it here).

This is what a thumbnail needs and what a fake surface cannot give: SHM-BUFFER-POINTER
needs a mapped pool, so a snapshot of a fake buffer is correctly *no picture* --
which is the other half of the same rule."
  (let* ((stride (* 4 width))
         (size (* stride height))
         (fd (wayland.ffi:memfd-create "cl-wayland-switcher-picture"))
         (octets (picture-octets width height left right)))
    (wayland.ffi:set-file-size fd size)
    (let ((mapping (wayland.ffi:map-file fd size
                                         :protection (logior wayland.ffi:+prot-read+
                                                             wayland.ffi:+prot-write+))))
      (unwind-protect
           (wayland.ffi:write-mapped-octets mapping 0 octets)
        (wayland.ffi:unmap-file mapping size)))
    (let* ((pool (make-instance 'srv:shm-pool :client nil :id 20 :interface nil
                                              :version 1 :fd fd :size size))
           ;; Mapped read-write, unlike a pool's: the test plays the client, and a
           ;; client writes its own pixels.  Reading is all the renderer does with it.
           (mapping (wayland.ffi:map-file fd size
                                          :protection (logior wayland.ffi:+prot-read+
                                                              wayland.ffi:+prot-write+)))
           (buffer (make-instance 'srv:shm-buffer :pool pool :offset 0
                                                 :width width :height height
                                                 :stride stride :format 0)))
      (setf (srv:shm-pool-mapping pool) mapping
            (srv::shm-pool-mapping-length pool) size)
      (values buffer fd mapping size))))

(defun fill-picture (mapping width height colour)
  "Overwrite every pixel in MAPPING with COLOUR, as a client redrawing would."
  (let ((octets (make-array (* 4 width height) :element-type '(unsigned-byte 8))))
    (dotimes (index (* width height))
      (setf (aref octets (* 4 index)) (ldb (byte 8 0) colour)
            (aref octets (+ (* 4 index) 1)) (ldb (byte 8 8) colour)
            (aref octets (+ (* 4 index) 2)) (ldb (byte 8 16) colour)
            (aref octets (+ (* 4 index) 3)) (ldb (byte 8 24) colour)))
    (wayland.ffi:write-mapped-octets mapping 0 octets)
    colour))

(defun snapshot-nodes (compositor)
  "The overlay's pictures, in draw order -- one per row that has one."
  (remove-if-not (lambda (node) (typep node 'scene:snapshot-node))
                 (scene-overlay-children compositor)))

(defun raster-pixel (octets width x y)
  "The 0xAARRGGBB pixel at (X, Y) of an ARGB8888 raster WIDTH pixels wide."
  (let ((offset (* 4 (+ x (* width y)))))
    (logior (aref octets offset)
            (ash (aref octets (+ offset 1)) 8)
            (ash (aref octets (+ offset 2)) 16)
            (ash (aref octets (+ offset 3)) 24))))

(defun focus-stack-of (compositor)
  (cf:compositor-focus-stack compositor))

(defun scene-overlay-children (compositor)
  (scene:node-children (scene:scene-overlay (cf:compositor-scene compositor))))

(defun root-children (compositor)
  (scene:node-children (scene:scene-root (cf:compositor-scene compositor))))

(defun focused-surface (compositor)
  (srv:seat-keyboard-focus (cf:compositor-seat compositor)))

(defun install-switcher-binding (compositor)
  "Bind Alt+Tab to the switcher, the way a compositor declares it wants one.

The framework's default table still cycles the stack directly (FOCUS-STACK-CYCLE):
one of these two is a decision a compositor makes, and the default is the one that
puts nothing on the screen."
  (cf:add-keybinding compositor "Tab"
                     (lambda () (cf:start-switcher compositor))
                     :modifiers input:+modifier-mod1+
                     :description "switcher")
  compositor)

(defun three-windows (compositor)
  "Windows A, B and C mapped and focused in that order: the stack is (C B A).
Returns the three surfaces as a list (A B C), in the order they were focused."
  (let ((a (window compositor :title "ALPHA" :x 0))
        (b (window compositor :title "BETA" :x 40))
        (c (window compositor :title "GAMMA" :x 80)))
    (dolist (surface (list a b c))
      (cf:focus-surface compositor surface))
    (list a b c)))

;;; ---------------------------------------------------------------------------
;;; The font (D51)
;;; ---------------------------------------------------------------------------

(deftest the-font-has-every-printable-ascii-glyph
  (ok (= 95 (font:glyph-count)) "printable ASCII is 95 characters")
  (ok (loop for code from font:+first-char-code+ to font:+last-char-code+
            always (loop for row from 0 below font:+glyph-height+
                         always (typep (font:glyph-row-mask (code-char code) row)
                                       '(unsigned-byte 5))))
      "every glyph is seven rows of five bits")
  (ok (loop for character across "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
            always (loop for row from 0 below font:+glyph-height+
                         thereis (plusp (font:glyph-row-mask character row))))
      "every letter and digit draws something")
  (ok (notany (lambda (row) (plusp (font:glyph-row-mask #\Space row)))
              '(0 1 2 3 4 5 6))
      "and a space draws nothing at all")
  (ok (plusp (font:glyph-row-mask (code-char 0) 0))
      "a character outside the table falls back to a glyph that is visible"))

(deftest text-width-is-six-per-glyph-less-the-last-gap
  (ok (= 0 (font:text-width "")) "empty text occupies nothing")
  (ok (= 5 (font:text-width "A")) "one glyph is five cells wide")
  (ok (= 11 (font:text-width "AB")) "two glyphs are eleven: five, a gap, five")
  (ok (= 7 (font:text-height)) "and the height is seven cells"))

(deftest a-raster-is-premultiplied-and-sized
  (let ((colour #xFFE8E8E8))
    (multiple-value-bind (octets width height) (font:rasterize-text "A" colour 1)
      (ok (= 5 width) "one glyph is five pixels wide")
      (ok (= 7 height) "and seven tall")
      (ok (= (* 4 5 7) (length octets)) "four octets per pixel")
      ;; A is "..#../.#.#./#...#/#...#/#####/#...#/#...#".
      (ok (= colour (raster-pixel octets width 2 0)) "the apex cell is the colour")
      (ok (= 0 (raster-pixel octets width 0 0)) "a clear cell is fully transparent")
      (ok (= colour (raster-pixel octets width 0 4)) "the crossbar reaches the left edge")
      (ok (= #xFF (ldb (byte 8 24) colour)) "and the colour is opaque, as text is"))))

(deftest a-raster-at-scale-two-is-two-pixels-per-cell
  (multiple-value-bind (octets width height) (font:rasterize-text "A" #xFFFFFFFF 2)
    (ok (= 10 width) "five cells at two pixels each")
    (ok (= 14 height) "seven rows at two pixels each")
    (ok (= #xFFFFFFFF (raster-pixel octets width 4 0))
        "the apex cell is a 2x2 block, drawn rather than upscaled")
    (ok (= #xFFFFFFFF (raster-pixel octets width 5 1)) "including its far corner")
    (ok (= 0 (raster-pixel octets width 3 0)) "and the block next to it is clear")))

(deftest two-glyphs-have-a-clear-column-between-them
  (multiple-value-bind (octets width height) (font:rasterize-text "II" #xFFFFFFFF 1)
    (declare (ignore height))
    (ok (= 11 width))
    (ok (notany (lambda (y) (plusp (raster-pixel octets width 5 y))) '(0 1 2 3 4 5 6))
        "the gap column belongs to no glyph")))

(deftest an-unknown-character-draws-the-fallback
  (let ((unknowns (coerce (list (code-char 1) (code-char 200)) 'string)))
    (multiple-value-bind (substitute) (font:rasterize-text unknowns #xFFFFFFFF 1)
      (multiple-value-bind (fallbacks) (font:rasterize-text "??" #xFFFFFFFF 1)
        (ok (equalp substitute fallbacks)
            "a character outside the table is drawn as the fallback glyph, not dropped")))))

(deftest truncate-text-cuts-with-an-ellipsis
  (let ((title "ABCDEFGHIJ"))
    (ok (string= title (font:truncate-text title (font:text-width title)))
        "a title that fits is returned unchanged")
    (ok (string= "AB..." (font:truncate-text title 29))
        "a title that does not is cut, and the ellipsis is inside the width")
    (ok (<= (font:text-width (font:truncate-text title 29)) 29)
        "the cut result really fits")
    (ok (string= "" (font:truncate-text title 10))
        "and too little room for three dots is no text, not a broken one")))

(deftest a-text-node-measures-in-layout-pixels
  (let ((node (scene:make-text-node "title" :colour #xFF00FF00)))
    (ok (= (font:text-width "title") (scene:node-width node))
        "the node is as wide as the font says, in layout pixels")
    (ok (= 7 (scene:node-height node)) "and seven layout pixels tall")
    (multiple-value-bind (octets width height) (scene:text-node-raster node 2)
      (ok (= (* 2 (scene:node-width node)) width) "its raster is twice as wide at scale 2")
      (ok (= 14 height))
      (ok (plusp (length octets))))
    (let ((node (scene:make-text-node "")))
      (ok (zerop (scene:node-width node)) "empty text has no width")
      (ok (zerop (scene:node-height node)) "and no height"))))

;;; ---------------------------------------------------------------------------
;;; The scene's overlay (D51)
;;; ---------------------------------------------------------------------------

(deftest the-overlay-is-drawn-above-the-windows-and-below-the-cursor
  (let* ((scene (scene:make-scene 100 100))
         (window (scene:scene-add-node scene
                                       (scene:make-buffer-node
                                        (fake-surface :width 20 :height 20 :mapped-p t))))
         (overlay (scene:scene-add-overlay-node scene
                                                (scene:make-rect-node 10 10 #xFF3050A0)
                                                :x 5 :y 5))
         (items (scene:scene-draw-list scene)))
    (ok (equal (list window overlay)
               (mapcar #'scene:draw-item-node (butlast items)))
        "the tree, then the overlay, then (below) the cursor")
    (ok (eq (scene:scene-cursor scene) (scene:draw-item-node (car (last items))))
        "the pointer is still the last thing drawn")
    (ok (= 5 (scene:draw-item-x (second items))) "and the overlay is where it was put")))

(deftest the-overlay-is-not-hit-tested
  (let* ((scene (scene:make-scene 100 100))
         (window (scene:scene-add-node scene
                                       (scene:make-buffer-node
                                        (fake-surface :width 40 :height 40 :mapped-p t))))
         (overlay (scene:scene-add-overlay-node scene
                                                (scene:make-rect-node 60 60 #xFF3050A0))))
    (declare (ignore overlay))
    (multiple-value-bind (hit) (scene:scene-hit-test scene 10 10)
      (ok (eq window hit)
          "a click inside the overlay reaches the window under it, not the overlay"))
    (ok (equal (list window) (scene:node-children (scene:scene-root scene)))
        "and the overlay never became a child of the tree")))

(deftest clearing-the-overlay-removes-every-node
  (let* ((scene (scene:make-scene 100 100)))
    (scene:scene-add-overlay-node scene (scene:make-rect-node 10 10 #xFF000000))
    (scene:scene-add-overlay-node scene (scene:make-text-node "hello"))
    (ok (= 2 (length (scene:node-children (scene:scene-overlay scene)))))
    (ok (= 2 (scene:scene-clear-overlay scene)) "two nodes went away")
    (ok (null (scene:node-children (scene:scene-overlay scene))) "and none are left")
    (ok (zerop (scene:scene-clear-overlay scene)) "clearing twice is not an error")))

;;; ---------------------------------------------------------------------------
;;; Titles
;;; ---------------------------------------------------------------------------

(deftest a-window-is-named-by-its-title-then-its-app-id-then-nothing
  (with-compositor (compositor)
    (multiple-value-bind (titled) (window compositor :title "real title" :app-id "app")
      (ok (equal "real title" (cf:window-title titled)) "the client's title wins"))
    (multiple-value-bind (app-id-only) (window compositor :app-id "org.example.App")
      (ok (equal "org.example.App" (cf:window-title app-id-only))
          "an app id is the next best name -- a client that sets no title still has one"))
    (multiple-value-bind (anonymous) (window compositor)
      (ok (null (cf:window-title anonymous)) "and a window with neither has no name"))
    (ok (null (cf:window-title (fake-surface :mapped-p t)))
        "a surface with no role is nobody's window")))

;;; ---------------------------------------------------------------------------
;;; What the switcher lists
;;; ---------------------------------------------------------------------------

(deftest the-switcher-lists-the-focus-stack-from-its-tail
  (with-compositor (compositor)
    (destructuring-bind (a b c) (three-windows compositor)
      (ok (equal (list c b a) (focus-stack-of compositor)) "the stack is history, newest first")
      (let ((switcher (sw:start-switcher compositor)))
        (ok (eq switcher (cf:compositor-switcher compositor)) "the compositor holds it")
        (ok (sw:switcher-open-p switcher) "and it is open")
        (ok (equal (list a b c) (sw:switcher-entries switcher))
            "row 0 is the tail -- what one tap of Tab would choose (D45)")
        (ok (zerop (sw:switcher-index switcher)) "and the selection starts there")
        (ok (eq a (sw:switcher-selected switcher)))
        (ok (equal '("ALPHA" "BETA" "GAMMA") (sw:switcher-titles switcher))
            "with the clients' titles, in the same order")))))

(deftest the-switcher-does-not-touch-the-stack-while-it-is-open
  (with-compositor (compositor)
    (destructuring-bind (a b c) (three-windows compositor)
      (declare (ignore a b))
      (let ((stack (copy-list (focus-stack-of compositor)))
            (front (car (last (root-children compositor)))))
        (sw:start-switcher compositor)
        (sw:advance-switcher compositor 1)
        (ok (equal stack (focus-stack-of compositor))
            "walking the list does not reorder the history")
        (ok (eq front (car (last (root-children compositor))))
            "and does not restack the windows")
        (ok (eq c (focused-surface compositor))
            "or move the keyboard before the choice is made")))))

(deftest advance-walks-forwards-and-wraps
  (with-compositor (compositor)
    (destructuring-bind (a b c) (three-windows compositor)
      (let ((switcher (sw:start-switcher compositor)))
        (declare (ignore switcher))
        (sw:advance-switcher compositor 1)
        (ok (= 1 (sw:switcher-index (cf:compositor-switcher compositor))))
        (ok (eq b (sw:switcher-selected (cf:compositor-switcher compositor))))
        (sw:advance-switcher compositor 1)
        (ok (eq c (sw:switcher-selected (cf:compositor-switcher compositor))))
        (sw:advance-switcher compositor 1)
        (ok (= 0 (sw:switcher-index (cf:compositor-switcher compositor)))
            "a fourth step wraps to the first row")
        (ok (eq a (sw:switcher-selected (cf:compositor-switcher compositor))))
        (sw:advance-switcher compositor -1)
        (ok (eq c (sw:switcher-selected (cf:compositor-switcher compositor)))
            "and going backwards wraps the other way")))))

(deftest the-highlight-moves-with-the-selection
  (with-compositor (compositor)
    (three-windows compositor)
    (let* ((switcher (sw:start-switcher compositor))
           (highlight (sw:switcher-highlight switcher))
           (layout (sw:switcher-layout switcher)))
      (multiple-value-bind (x y) (scene:node-position highlight)
        (ok (= (+ (getf layout :x) 2) x) "the bar starts two pixels inside the panel")
        (ok (= (first (getf layout :rows)) y) "on the first row")
        (ok (= (first (getf layout :row-heights)) (scene:node-height highlight))
            "as tall as that row"))
      (sw:advance-switcher compositor 1)
      (multiple-value-bind (x y) (scene:node-position highlight)
        (declare (ignore x))
        (ok (= (second (getf layout :rows)) y) "and one row down after a step")
        (ok (= (second (getf layout :row-heights)) (scene:node-height highlight))
            "with the second row's height")))))

(deftest a-long-title-is-cut-instead-of-widening-the-panel
  (with-compositor (compositor :width 200 :height 100)
    (let ((long (make-string 60 :initial-element #\W)))
      (cf:focus-surface compositor (window compositor :title long))
      (cf:focus-surface compositor (window compositor :title "short"))
      (let* ((switcher (sw:start-switcher compositor))
             (layout (sw:switcher-layout switcher)))
        (ok (<= (+ (getf layout :x) (getf layout :width)) 200)
            "the panel fits inside the output")
        (ok (<= (getf layout :width) 200) "because the title was cut, not the panel")
        (ok (string= "..." (subseq (first (sw:switcher-titles switcher))
                                   (- (length (first (sw:switcher-titles switcher))) 3)))
            "and the cut says so")))))

(deftest a-window-with-no-name-still-gets-a-row
  (with-compositor (compositor)
    (cf:focus-surface compositor (window compositor :title "named"))
    (cf:focus-surface compositor (window compositor))
    (let ((switcher (sw:start-switcher compositor)))
      (ok (member sw:+switcher-fallback-title+ (sw:switcher-titles switcher)
                  :test #'string=)
          "a nameless client is drawn as a stand-in word, not an empty row")
      (ok (every (lambda (title) (plusp (length title))) (sw:switcher-titles switcher))))))

;;; ---------------------------------------------------------------------------
;;; Pictures in the rows (D52)
;;; ---------------------------------------------------------------------------

(deftest a-thumbnail-fits-the-box-without-stretching
  ;; The box is a limit, not a shape: a wide window keeps its shape and a small one
  ;; is shown at its own size rather than blown up.
  (multiple-value-bind (width height) (sw:thumbnail-size 742 499)
    (ok (<= width sw:+switcher-thumbnail-width+) "a wide window fits the box's width")
    (ok (<= height sw:+switcher-thumbnail-height+) "and its height")
    (ok (= height sw:+switcher-thumbnail-height+) "filling the height it is limited by")
    (ok (< (abs (- (/ 742 499) (/ width height))) 0.05)
        "with the window's aspect ratio, not the box's"))
  (multiple-value-bind (width height) (sw:thumbnail-size 48 160)
    (ok (<= width sw:+switcher-thumbnail-width+) "a tall window fits the width")
    (ok (<= height sw:+switcher-thumbnail-height+) "and the height"))
  (multiple-value-bind (width height) (sw:thumbnail-size 20 10)
    (ok (= 20 width) "a small window is not upscaled")
    (ok (= 10 height) "in either direction")))

(deftest a-row-with-a-picture-is-taller-and-names-itself-after-it
  (with-compositor (compositor :width 640 :height 480)
    (multiple-value-bind (picture-buffer fd mapping size)
        (picture-buffer 100 80 :left #xFFFF0000 :right #xFF0000FF)
      (declare (ignore size))
      (unwind-protect
           (let ((with-picture (window compositor :title "PICTURE" :buffer picture-buffer))
                 (without (window compositor :title "NOBODY" :width 100 :height 80)))
             (cf:focus-surface compositor with-picture)
             (cf:focus-surface compositor without)
             (let* ((switcher (sw:start-switcher compositor))
                    (layout (sw:switcher-layout switcher)))
               (ok (eq with-picture (first (sw:switcher-entries switcher)))
                   "the picture row is the one whose window has pixels")
               (ok (= 2 (length (getf layout :thumbnails))))
               (destructuring-bind (x y width height) (first (getf layout :thumbnails))
                 (ok (= (+ (getf layout :x) (getf layout :padding)) x)
                     "the picture starts at the panel's inner edge")
                 (ok (= 60 width) "a 100x80 window is fitted to 60x48 in the box")
                 (ok (= 48 height))
                 (ok (and (<= (first (getf layout :rows)) y)
                          (<= (+ y height)
                              (+ (first (getf layout :rows))
                                 (first (getf layout :row-heights)))))
                     "and sits inside its own row, not over the next one"))
               (ok (null (second (getf layout :thumbnails)))
                   "a window with no pixels gets no picture, not a placeholder")
               (ok (> (first (getf layout :row-heights)) 16)
                   "a row with a picture is taller than a title-only row")
               (ok (= 16 (second (getf layout :row-heights))))
               (ok (= (+ (getf layout :x) (getf layout :padding)
                         sw:+switcher-thumbnail-width+ sw:+switcher-thumbnail-gap+)
                      (getf layout :text-x))
                   "and every title starts in one column, after the picture's")
               (ok (= 1 (length (snapshot-nodes compositor)))
                   "one picture node went into the overlay")))
        (wayland.ffi:unmap-file mapping (* 100 4 80))
        (wayland.ffi:close-fd fd)))))

(deftest a-thumbnail-is-the-windows-own-picture-at-the-outputs-scale
  ;; The picture is taken at the resolution it will be drawn at, so drawing it is a
  ;; copy: two flat halves stay two flat halves, at either scale, and the boundary
  ;; stays in the middle -- which is what says the picture is this window, the right
  ;; way up, at the size the layout chose.
  (dolist (scale '(1 2))
    (with-compositor (compositor :width 320 :height 240 :scale scale)
      (multiple-value-bind (picture-buffer fd mapping size)
          (picture-buffer 16 8 :left #xFF00FF00 :right #xFFFFFF00)
        (declare (ignore size))
        (unwind-protect
             (let ((picture (window compositor :title "BOTH" :buffer picture-buffer
                                    :width 16 :height 8)))
               (cf:focus-surface compositor picture)
               (cf:focus-surface compositor (window compositor :title "OTHER"))
               (sw:start-switcher compositor)
               (let* ((node (first (snapshot-nodes compositor)))
                      (octets (scene:bitmap-node-octets node))
                      (width (scene:bitmap-node-source-width node))
                      (height (scene:bitmap-node-source-height node)))
                 (ok node "the window with pixels has a picture")
                 (ok (= (* 16 scale) width) "the picture is as wide as the window, times the scale")
                 (ok (= (* 8 scale) height) "and as tall")
                 (ok (= #xFF00FF00 (raster-pixel octets width 1 (floor height 2)))
                     (format nil "at scale ~D the left half is the window's left half"
                             scale))
                 (ok (= #xFFFFFF00 (raster-pixel octets width (- width 2) (floor height 2)))
                     "and the right half is its right half")
                 (ok (= (* 16 scale) (scene:draw-item-width
                                      (find node (scene:scene-draw-list (cf:compositor-scene compositor))
                                            :key #'scene:draw-item-node)))
                     "and it is drawn at the box's layout size, times the scale")))
          (wayland.ffi:unmap-file mapping (* 16 4 8))
          (wayland.ffi:close-fd fd))))))

(deftest a-thumbnail-is-taken-once-and-not-followed-around
  ;; A client may repaint whenever it likes.  The picture in the row does not move
  ;; with it: it is what the window looked like when the switcher opened (D52), so a
  ;; painting client cannot make the panel repaint, and cannot make the picture
  ;; sometimes-stale -- it is always the picture that was taken.
  (with-compositor (compositor :width 320 :height 240)
    (multiple-value-bind (picture-buffer picture-fd picture-mapping picture-size)
        (picture-buffer 16 8 :left #xFF00FF00 :right #xFFFFFF00)
      (declare (ignore picture-size))
      (unwind-protect
           (multiple-value-bind (other-buffer other-fd other-mapping other-size)
               (picture-buffer 16 8 :left #xFFFF00FF :right #xFFFF00FF)
             (declare (ignore other-size))
             (unwind-protect
                  (let ((picture (window compositor :title "BOTH" :buffer picture-buffer
                                         :width 16 :height 8)))
                    (cf:focus-surface compositor picture)
                    (cf:focus-surface compositor
                                          (window compositor :title "OTHER"
                                                             :buffer other-buffer
                                                             :width 16 :height 8))
                    (let* ((switcher (sw:start-switcher compositor))
                           (node (first (snapshot-nodes compositor)))
                           (octets (scene:bitmap-node-octets node)))
                      ;; The client redraws: every pixel of its buffer becomes red.
                      (fill-picture picture-mapping 16 8 #xFFFF0000)
                      (sw:advance-switcher compositor 1)
                      (ok (eq octets (scene:bitmap-node-octets node))
                          "walking the list does not re-take the picture")
                      (ok (= #xFF00FF00 (raster-pixel octets
                                                      (scene:bitmap-node-source-width node)
                                                      1 4))
                          "and it still says what it said when it was taken")
                      (cf:render-frame compositor)
                      (let* ((layout (sw:switcher-layout switcher))
                             (rect (first (getf layout :thumbnails))))
                        (ok (= #xFF00FF00
                               (cf:frame-pixel compositor (+ (first rect) 1)
                                               (+ (second rect) 3)))
                            "the frame still draws the picture, not the client's new pixels"))))
               (wayland.ffi:unmap-file other-mapping (* 16 4 8))
               (wayland.ffi:close-fd other-fd)))
        (wayland.ffi:unmap-file picture-mapping (* 16 4 8))
        (wayland.ffi:close-fd picture-fd)))))

(deftest a-window-with-no-pixels-gets-the-title-only-switcher
  ;; The layout a compositor gets when nothing has a picture is the one it had before
  ;; pictures existed: no gutter, no taller rows (D51's arithmetic, unchanged).
  (with-compositor (compositor)
    (destructuring-bind (a b c) (three-windows compositor)
      (declare (ignore a b c))
      (let* ((switcher (sw:start-switcher compositor))
             (layout (sw:switcher-layout switcher)))
        (ok (every #'null (sw:switcher-snapshots switcher))
            "a buffer with no pool behind it is no picture")
        (ok (every #'null (getf layout :thumbnails)))
        (ok (= (+ (getf layout :x) (getf layout :padding)) (getf layout :text-x))
            "so the titles start at the panel's inner edge, as they always did")
        (ok (equal '(16 16 16) (getf layout :row-heights))
            "and every row is the title's row")
        (ok (= (+ (* 3 16) (* 2 (getf layout :padding))) (getf layout :height)))
        (ok (zerop (length (snapshot-nodes compositor))) "with no picture nodes")))))

(deftest set-node-size-resizes-what-the-compositor-owns
  (let ((rect (scene:make-rect-node 10 4 #xFF000000)))
    (scene:set-node-size rect 40 7)
    (ok (= 40 (scene:node-width rect)) "a rectangle is the compositor's to size")
    (ok (= 7 (scene:node-height rect)))
    (let ((buffer-node (scene:make-buffer-node (fake-surface :mapped-p t))))
      (ok (handler-case (progn (scene:set-node-size buffer-node 10 10) nil)
              (error () t))
          "a client's buffer is not: its size is the client's answer")))
  (let ((picture (scene:make-image-node (make-array 4 :element-type '(unsigned-byte 8)) 1 1)))
    (scene:set-node-size picture 32 32)
    (ok (= 32 (scene:node-width picture))
        "a bitmap's drawn size is ours")
    (ok (= 1 (scene:bitmap-node-source-width picture))
        "and its pixel size is the picture's")))


(deftest one-window-is-not-a-choice
  (with-compositor (compositor)
    (let ((a (window compositor :title "only")))
      (cf:focus-surface compositor a)
      (ok (null (sw:start-switcher compositor)) "nothing opens for one window")
      (ok (null (cf:compositor-switcher compositor)) "and nothing is left behind")
      (ok (zerop (length (scene-overlay-children compositor))) "with no overlay nodes"))))

(deftest alt-tab-opens-the-switcher-and-proves-the-key-path
  (with-compositor (compositor)
    (destructuring-bind (a b c) (three-windows compositor)
      (declare (ignore a b))
      (install-switcher-binding compositor)
      (cf:inject-key compositor "Alt_L" :pressed)
      (ok (eq t (cf:inject-key compositor "Tab" :pressed))
          "the Tab press was consumed: the client never sees it")
      (ok (sw:switcher-open-p (cf:compositor-switcher compositor)))
      (ok (equal '("Tab") (cf:compositor-consumed-keys compositor))
          "and remembered, so no client hears its release either")
      (ok (eq t (cf:inject-key compositor "Tab" :released)) "the release was consumed")
      (ok (null (cf:compositor-consumed-keys compositor)) "and then forgotten")
      (ok (eq c (focused-surface compositor))
          "opening the overlay changes nothing about the focus"))))

(deftest shifting-the-selection-is-not-releasing-alt
  (with-compositor (compositor)
    (three-windows compositor)
    (cf:inject-key compositor "Alt_L" :pressed)
    (let ((switcher (sw:start-switcher compositor)))
      (cf:inject-key compositor "Shift_L" :pressed)
      (ok (eq switcher (cf:compositor-switcher compositor))
          "pressing a modifier does not cancel the switcher")
      (cf:inject-key compositor "Shift_L" :released)
      (ok (sw:switcher-open-p switcher)
          "and releasing one that is not Alt does not commit it"))))

(deftest shift-tab-walks-backwards
  (with-compositor (compositor)
    (destructuring-bind (a b c) (three-windows compositor)
      (install-switcher-binding compositor)
      (cf:inject-key compositor "Alt_L" :pressed)
      (cf:inject-key compositor "Tab" :pressed)      ; opens, on row 0
      (cf:inject-key compositor "Tab" :released)
      (cf:inject-key compositor "Shift_L" :pressed)
      (cf:inject-key compositor "Tab" :pressed)      ; and now go backwards
      (ok (= 2 (sw:switcher-index (cf:compositor-switcher compositor)))
          "a backwards step from the first row wraps to the last")
      (ok (eq c (sw:switcher-selected (cf:compositor-switcher compositor))))
      (cf:inject-key compositor "Tab" :released)
      (cf:inject-key compositor "Tab" :pressed)
      (ok (eq b (sw:switcher-selected (cf:compositor-switcher compositor)))
          "and the second step is the one before it")
      (ok (eq a (first (sw:switcher-entries (cf:compositor-switcher compositor))))
          "the list itself never reordered"))))

(deftest start-switcher-can-open-backwards
  ;; Alt+Shift+Tab is one binding away from this: cl-tinywl passes :step -1, so the
  ;; overlay opens on the window that has the keys now rather than on the tail.
  (with-compositor (compositor)
    (destructuring-bind (a b c) (three-windows compositor)
      (declare (ignore b))
      (let ((switcher (sw:start-switcher compositor :step -1)))
        (ok (= 2 (sw:switcher-index switcher)) "the last row is the focused window")
        (ok (eq c (sw:switcher-selected switcher))))
      (ok (eq a (first (sw:switcher-entries (cf:compositor-switcher compositor))))
          "and the list is still the stack from its tail"))))

(deftest releasing-alt-takes-the-row-and-raises-it
  (with-compositor (compositor)
    (destructuring-bind (a b c) (three-windows compositor)
      (install-switcher-binding compositor)
      (cf:inject-key compositor "Alt_L" :pressed)
      (cf:inject-key compositor "Tab" :pressed)
      (cf:inject-key compositor "Tab" :released)
      (cf:inject-key compositor "Tab" :pressed)     ; select row 1: B
      (cf:inject-key compositor "Tab" :released)
      (ok (eq b (sw:switcher-selected (cf:compositor-switcher compositor))))
      (cf:inject-key compositor "Alt_L" :released)
      (ok (null (cf:compositor-switcher compositor)) "releasing Alt closed it")
      (ok (zerop (length (scene-overlay-children compositor)))
          "and took every overlay node with it")
      (ok (eq b (focused-surface compositor)) "the row it was showing has the keys")
      (ok (eq b (first (focus-stack-of compositor)))
          "and moved to the front of the history")
      (ok (equal (list b c a) (focus-stack-of compositor))
          "which is a rotation of the stack, not a reordering of the desktop")
      (ok (eq b (scene:buffer-node-surface (car (last (root-children compositor)))))
          "and was raised, because a choice you cannot see is not a choice"))))

(deftest escape-cancels-and-leaves-the-focus-alone
  (with-compositor (compositor)
    (destructuring-bind (a b c) (three-windows compositor)
      (declare (ignore a b))
      (install-switcher-binding compositor)
      (cf:inject-key compositor "Alt_L" :pressed)
      (cf:inject-key compositor "Tab" :pressed)
      (ok (eq t (cf:inject-key compositor "Escape" :pressed))
          "Escape is consumed: Alt is still down, and Alt+Escape is \"quit\"")
      (ok (null (cf:compositor-switcher compositor)) "but the switcher is gone")
      (ok (eq c (focused-surface compositor)) "with the focus exactly where it was"))))

(deftest a-pointer-press-cancels-the-switcher
  (with-compositor (compositor)
    (three-windows compositor)
    (sw:start-switcher compositor)
    (cf:inject-pointer-button compositor :left :pressed)
    (ok (null (cf:compositor-switcher compositor))
        "a click says the overlay was not what was wanted")
    (ok (zerop (length (scene-overlay-children compositor))))))

(deftest the-cancel-and-commit-calls-are-idempotent
  (with-compositor (compositor)
    (three-windows compositor)
    (sw:start-switcher compositor)
    (ok (sw:cancel-switcher compositor) "the first cancel finds it open")
    (ok (null (sw:cancel-switcher compositor)) "the second finds nothing")
    (ok (null (sw:commit-switcher compositor)) "and so does a commit with nothing to commit")))

(deftest a-window-that-vanished-is-not-chosen
  (with-compositor (compositor)
    (destructuring-bind (a b c) (three-windows compositor)
      (declare (ignore b))
      (sw:start-switcher compositor)
      (ok (eq a (sw:switcher-selected (cf:compositor-switcher compositor))))
      ;; The selected window's client goes away while the overlay is up.
      (setf (srv:surface-mapped-p a) nil)
      (ok (null (sw:commit-switcher compositor))
          "committing does not focus a window that is gone")
      (ok (eq c (focused-surface compositor)) "the keys stay where they were")
      (ok (zerop (length (scene-overlay-children compositor)))
          "and the overlay comes down anyway"))))

(deftest a-compositor-without-a-switcher-binding-still-cycles
  ;; The framework's default table is FOCUS-STACK-CYCLE: the overlay is a
  ;; compositor's choice, and one that has not made it keeps the old behaviour
  ;; (D45's cycle, gate clause 18).
  (with-compositor (compositor)
    (destructuring-bind (a b c) (three-windows compositor)
      (declare (ignore b c))
      (cf:inject-key compositor "Alt_L" :pressed)
      (ok (eq t (cf:inject-key compositor "Tab" :pressed)))
      (ok (null (cf:compositor-switcher compositor))
          "no switcher binding, no overlay")
      (ok (eq a (focused-surface compositor))
          "the stack cycle ran instead, and chose what it always chose"))))

(deftest an-empty-cycle-is-not-an-error
  (with-compositor (compositor)
    (ok (null (sw:start-switcher compositor)) "no windows, nothing to show")
    (ok (null (sw:advance-switcher compositor 1)) "and nothing to advance")
    (ok (null (sw:commit-switcher compositor)))
    (ok (null (sw:cancel-switcher compositor)))))

;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; cl-tinywl's policy, without clients.
;;;;
;;;; Everything here is a decision tinywl.c makes and a gate cannot isolate: which
;;;; edge a press asks for, where a window is placed, what Alt+left does to a node,
;;;; how big a resize asks the client to be, which keys are the compositor's.  The
;;;; behaviour those decisions add up to needs two real clients and lives in
;;;; scripts/tinywl-parity.lisp.
;;;;
;;;; A surface is faked the way the scene tests fake one -- a wl_surface with a
;;;; buffer of a known size and a client whose only role is to have an id, since
;;;; the log line the framework writes about a placed window names it.

(in-package #:cl-user)

(defpackage #:wayland.test.tinywl
  (:use #:cl #:rove)
  (:local-nicknames (#:srv #:wayland.server)
                    (#:scene #:cf.scene)
                    (#:grab #:cf.grab)
                    (#:kb #:cf.keybindings)
                    (#:input #:cf.input))
  (:documentation "Tests for cl-tinywl: placement, edges, drags and bindings."))

(in-package #:wayland.test.tinywl)

;;; ---------------------------------------------------------------------------
;;; Fixtures
;;; ---------------------------------------------------------------------------

(defparameter *background* #xFF000000 "The compositor's background, as a pixel.")

(defvar *directory-counter* 0)

(defun make-test-directory ()
  (let ((path (format nil "/tmp/cl-wayland-tinywl-test-~D-~D/"
                      (get-universal-time) (incf *directory-counter*))))
    (ensure-directories-exist path)
    (wayland.ffi:chmod-path (string-right-trim "/" path) #o700)
    path))

(defmacro with-tinywl ((tinywl &key (width 512) (height 512) (scale 1)) &body body)
  "A tinywl compositor on a private socket, and a quiet server."
  (let ((directory (gensym "DIRECTORY")))
    `(let ((,directory (make-test-directory))
           (srv:*log-level* :warn))
       (unwind-protect
            (let ((,tinywl (tinywl:make-tinywl :width ,width :height ,height :scale ,scale
                                               :display-name "tinywl-test-0"
                                               :runtime-dir ,directory)))
              (unwind-protect (locally ,@body)
                (srv:close-display (cf:compositor-display ,tinywl))))
         (ignore-errors (uiop:delete-directory-tree (pathname ,directory)
                                                    :validate t))))))

(defun fake-window (tinywl &key (width 200) (height 150) (x 0) (y 0))
  "A mapped surface with a buffer of WIDTH x HEIGHT, and its scene node at (X, Y).

The client is a client object with an id and a descriptor that is never used: the
surface needs one because a placed window is logged by client id, and a real
connection would make this a gate rather than a test."
  (let* ((display (cf:compositor-display tinywl))
         (client (make-instance 'srv:client :id 99 :display display :fd -1))
         (surface (make-instance 'cf:cf-surface
                                 :client client :id 9 :interface nil :version 1))
         (buffer (make-instance 'srv:shm-buffer
                                :pool nil :offset 0
                                :width width :height height
                                :stride (* 4 width) :format 0))
         (node (cf:on-new-toplevel tinywl surface)))
    (setf (srv:surface-current-buffer surface) buffer
          (srv:surface-mapped-p surface) t)
    (scene:set-node-position node x y)
    surface))

;;; ---------------------------------------------------------------------------
;;; Edges
;;; ---------------------------------------------------------------------------



(deftest a-client-border-is-where-the-pointer-can-reach-it
  ;; A client-side decoration sets an input region that excludes its shadow, so the
  ;; visible left border sits inside the surface's bounding box.  Measuring the grab
  ;; margin from the box put that border outside it and read a press on it as "the
  ;; body", which resized from the bottom-right -- the sixth manual test's "the wrong
  ;; border moves" (D42).
  (with-tinywl (tinywl)
    (let* ((surface (fake-window tinywl :width 806 :height 563))
           (node (cf:surface-scene-node surface)))
      ;; weston-terminal's own numbers: a 32-pixel shadow on every side.
      (setf (srv:surface-input-region surface) '((32 32 742 499)))
      (multiple-value-bind (left top width height) (tinywl:pointer-reach node)
        (ok (equal (list left top width height) '(32 32 742 499))
            (format nil "the reach of the window is its input region in output space (~S)"
                    (list left top width height))))
      (ok (= grab:+edge-left+ (tinywl:edges-at node 34 300))
          "two pixels inside the visible left border is the left edge")
      (ok (= grab:+edge-right+ (tinywl:edges-at node 770 300))
          "two pixels inside the visible right border is the right edge")
      (ok (= (logior grab:+edge-right+ grab:+edge-bottom+)
             (tinywl:edges-at node 400 300))
          "the middle of the window is still its bottom-right corner")
      ;; A surface with no input region is its own reach: every undecorated client.
      (setf (srv:surface-input-region surface) nil)
      (ok (= 806 (nth-value 2 (tinywl:pointer-reach node)))
          "a client with no input region reaches to its buffer's edge (806)"))))

(deftest a-window-with-no-geometry-is-its-own-buffer
  ;; Resize arithmetic is in window-geometry coordinates, because that is what an
  ;; xdg_toplevel.configure's size means.  A client that sets no geometry (no
  ;; client-side decoration) is its own buffer, which is every test client here.
  (with-tinywl (tinywl)
    (let* ((surface (fake-window tinywl :width 200 :height 150 :x 100 :y 50))
           (node (cf:surface-scene-node surface)))
      (multiple-value-bind (x y width height) (grab:node-geometry node)
        (ok (equal (list x y width height) '(0 0 200 150))
            (format nil "no geometry, so the buffer is the window (~S)"
                    (list x y width height))))
      (let ((resize (grab:begin-resize-grab node 295 125 grab:+edge-right+)))
        (ok (= 300 (grab:resize-grab-anchor-right resize))
            "and the anchored edge is the buffer's right edge")))))

(deftest edges-at-finds-the-side-the-pointer-is-on
  (let ((node (scene:make-rect-node 200 150 #xFF000000)))
    (scene:set-node-position node 100 50)
    (ok (= grab:+edge-left+ (tinywl:edges-at node 102 125))
        "two pixels in from the left is the left edge")
    (ok (= grab:+edge-right+ (tinywl:edges-at node 295 125))
        "five pixels in from the right is the right edge")
    (ok (= grab:+edge-top+ (tinywl:edges-at node 200 55))
        "five pixels below the top is the top edge")
    (ok (= grab:+edge-bottom+ (tinywl:edges-at node 200 195))
        "five pixels above the bottom is the bottom edge")
    (ok (= (logior grab:+edge-left+ grab:+edge-top+) (tinywl:edges-at node 105 52))
        "the top-left corner is both")
    (ok (= (logior grab:+edge-right+ grab:+edge-bottom+)
           (tinywl:edges-at node 295 195))
        "the bottom-right corner is both")
    (ok (= (logior grab:+edge-right+ grab:+edge-bottom+)
           (tinywl:edges-at node 200 120))
        "the body of the window is its bottom-right corner")))

;;; ---------------------------------------------------------------------------
;;; Placement
;;; ---------------------------------------------------------------------------

(deftest every-window-lands-at-the-origin-and-on-top
  ;; tinywl places nothing, so the second window covers the first and the stack is
  ;; the only thing that separates them.  This is the one place cl-tinywl
  ;; deliberately differs from the framework's cascade.
  (with-tinywl (tinywl)
    (let* ((first (fake-window tinywl))
           (second (fake-window tinywl))
           (root (scene:scene-root (cf:compositor-scene tinywl)))
           (children (scene:node-children root)))
      (ok (equal '(0 0) (multiple-value-list
                         (scene:node-position (cf:surface-scene-node first))))
          "the first window is at the origin")
      (ok (equal '(0 0) (multiple-value-list
                         (scene:node-position (cf:surface-scene-node second))))
          "and so is the second")
      (ok (eq (cf:surface-scene-node second) (car (last children)))
          "the window created last is drawn last"))))

;;; ---------------------------------------------------------------------------
;;; Hit testing
;;; ---------------------------------------------------------------------------

(deftest desktop-toplevel-at-finds-the-window-under-a-point
  (with-tinywl (tinywl)
    (let ((surface (fake-window tinywl :width 200 :height 150)))
      (multiple-value-bind (found x y) (tinywl:desktop-toplevel-at tinywl 100 75)
        (ok (eq surface found) "a point over the window finds it")
        (ok (= 100 x) "in the window's own coordinates")
        (ok (= 75 y)))
      (multiple-value-bind (found x y) (tinywl:desktop-toplevel-at tinywl 400 400)
        (declare (ignore x y))
        (ok (null found) "the bare output is nothing")))))

;;; ---------------------------------------------------------------------------
;;; Drags
;;; ---------------------------------------------------------------------------

(deftest a-move-grab-follows-the-pointer-and-stops
  (with-tinywl (tinywl)
    (let* ((surface (fake-window tinywl))
           (node (cf:surface-scene-node surface)))
      (cf:inject-pointer-motion tinywl 50 50)
      (ok (tinywl:begin-interactive tinywl surface :move) "a move grab starts")
      (ok (typep (cf:compositor-grab tinywl) 'grab:move-grab)
          "and it is a move grab")
      (cf:inject-pointer-motion tinywl 80 90)
      (ok (equal '(30 40) (multiple-value-list (scene:node-position node)))
          "the window followed the pointer's delta")
      (cf:inject-pointer-button tinywl :left :released)
      (ok (null (cf:compositor-grab tinywl)) "the release ended the grab")
      (cf:inject-pointer-motion tinywl 200 200)
      (ok (equal '(30 40) (multiple-value-list (scene:node-position node)))
          "and a later motion does not move it"))))

(deftest a-resize-grab-asks-for-the-size-the-edge-implies
  (with-tinywl (tinywl)
    (let* ((surface (fake-window tinywl))
           (node (cf:surface-scene-node surface)))
      ;; A press in the bottom-right corner, then a drag of (40, 30).
      (cf:inject-pointer-motion tinywl 195 145)
      (tinywl:begin-interactive tinywl surface :resize)
      (let ((grabbed (cf:compositor-grab tinywl)))
        (ok (typep grabbed 'grab:resize-grab) "a resize grab starts")
        (ok (= (logior grab:+edge-right+ grab:+edge-bottom+)
               (grab:resize-grab-edges grabbed))
            "from the corner the pointer is in"))
      (cf:inject-pointer-motion tinywl 235 175)
      (let ((grabbed (cf:compositor-grab tinywl)))
        (ok (= 240 (grab:resize-grab-requested-width grabbed))
            "the requested width is the window's plus the drag's")
        (ok (= 180 (grab:resize-grab-requested-height grabbed))
            "and so is the height"))
      (ok (= 200 (scene:node-width node))
          "the node is not resized by the grab: only the client can be"))))

;;; ---------------------------------------------------------------------------
;;; What a press means
;;; ---------------------------------------------------------------------------

(deftest alt-left-drags-and-alt-right-resizes
  (with-tinywl (tinywl)
    (let ((surface (fake-window tinywl)))
      (cf:inject-pointer-motion tinywl 100 75)
      (cf:inject-key tinywl "Alt_L" :pressed)
      (cf:inject-pointer-button tinywl :left :pressed)
      (ok (typep (cf:compositor-grab tinywl) 'grab:move-grab)
          "alt+left starts a move")
      (cf:inject-pointer-button tinywl :left :released)
      (ok (null (cf:compositor-grab tinywl)) "and the release ends it")

      (cf:inject-pointer-motion tinywl 195 145)
      (cf:inject-pointer-button tinywl :right :pressed)
      (let ((grabbed (cf:compositor-grab tinywl)))
        (ok (typep grabbed 'grab:resize-grab) "alt+right starts a resize")
        (ok (= (logior grab:+edge-right+ grab:+edge-bottom+)
               (grab:resize-grab-edges grabbed))
            "from the corner the pointer is in"))
      (cf:inject-pointer-button tinywl :right :released)
      (ok (null (cf:compositor-grab tinywl)) "and that release ends it")
      (cf:inject-key tinywl "Alt_L" :released)
      (ok surface "the window is still there"))))

(deftest a-press-without-alt-does-not-start-a-drag
  (with-tinywl (tinywl)
    (fake-window tinywl)
    (cf:inject-pointer-motion tinywl 100 75)
    (cf:inject-pointer-button tinywl :left :pressed)
    (ok (null (cf:compositor-grab tinywl))
        "a plain click is the client's, not a drag")
    (cf:inject-pointer-button tinywl :left :released)))

(deftest alt-on-the-bare-output-is-not-a-drag
  (with-tinywl (tinywl)
    (cf:inject-pointer-motion tinywl 400 400)
    (cf:inject-key tinywl "Alt_L" :pressed)
    (cf:inject-pointer-button tinywl :left :pressed)
    (ok (null (cf:compositor-grab tinywl))
        "there is nothing under the pointer to move")
    (cf:inject-pointer-button tinywl :left :released)
    (cf:inject-key tinywl "Alt_L" :released)))

;;; ---------------------------------------------------------------------------
;;; Keybindings
;;; ---------------------------------------------------------------------------

(deftest tinywl-installs-its-own-bindings
  ;; The framework's headless compositor installs Alt+Esc, Alt+Tab and Alt+F1 as
  ;; defaults.  A compositor whose behaviour cannot be read off its own source is one
  ;; whose bindings are somebody else's, so INSTALL-KEYBINDINGS replaces the table.
  (with-tinywl (tinywl)
    (let* ((table (cf:compositor-keybindings tinywl))
           (bindings (kb:keybinding-table-bindings table)))
      (ok (= 5 (length bindings)) "exactly five bindings")
      (ok (equal '("cycle windows" "quit" "switcher" "switcher backwards" "terminal")
                 (sort (mapcar #'kb:keybinding-description bindings) #'string<))
          "with tinywl's descriptions")
      (ok (every #'identity
                 (mapcar (lambda (binding)
                           (= input:+modifier-mod1+
                              (logand input:+modifier-mod1+
                                      (kb:keybinding-modifiers binding))))
                         bindings))
          "all of them on Alt")
      (ok (= 0 (tinywl:close-toplevels tinywl))
          "and closing a session with no windows asks nobody"))))

(deftest alt-escape-stops-the-compositor
  (with-tinywl (tinywl)
    (let ((reactor (srv:display-reactor (cf:compositor-display tinywl))))
      (cf:inject-key tinywl "Alt_L" :pressed)
      (cf:inject-key tinywl "Escape" :pressed)
      (ok (wayland.reactor:stopped-p reactor) "alt+Esc asks the loop to stop")
      ;; The release is swallowed too: the client never saw the press.
      (cf:inject-key tinywl "Escape" :released)
      (cf:inject-key tinywl "Alt_L" :released)
      (ok (null (cf:compositor-consumed-keys tinywl))
          "nothing is left marked as consumed"))))

;;; ---------------------------------------------------------------------------
;;; Resizing the output
;;; ---------------------------------------------------------------------------

(deftest resizing-an-output-resizes-the-scene-and-the-target
  ;; The nested backend follows a parent's configure by calling this (D37): the
  ;; output, the scene that hit-tests in its space, and the memory target all change
  ;; size together, because a target that did not would be written past its end.
  (with-tinywl (tinywl :width 100 :height 80)
    (let ((before (cf.backend.headless:compositor-target tinywl)))
      (cf:resize-compositor tinywl 200 120)
      (ok (= 200 (cf:compositor-width tinywl)) "the output reports its new width")
      (ok (= 120 (cf:compositor-height tinywl)) "and height")
      (ok (= 200 (scene:scene-width (cf:compositor-scene tinywl)))
          "the scene is sized with it, so hit testing stays in bounds")
      (ok (not (eq before (cf.backend.headless:compositor-target tinywl)))
          "the target was replaced, not resized in place")
      (cf:render-frame tinywl)
      (ok (= *background* (cf:frame-pixel tinywl 199 119))
          "a pixel only the new target has is readable"))))

(deftest a-scaled-session-draws-at-the-outputs-density
  ;; --scale N is how a session renders for a HiDPI output: the layout size the
  ;; session was asked for does not change, the target is N times as many pixels,
  ;; and a window's pixels land N pixels per layout pixel (D49).  A tinywl session
  ;; is where the number is *reached*: the flag goes in at the command line, through
  ;; START, to the compositor and the scene, and this is the arithmetic at the end.
  (with-tinywl (tinywl :width 100 :height 80 :scale 2)
    (ok (= 2 (cf:compositor-scale tinywl)) "the output is at scale 2")
    (ok (= 100 (cf:compositor-width tinywl)) "its layout width is unchanged")
    (ok (= 200 (cf:compositor-device-width tinywl)) "its target is twice as wide")
    (ok (= 2 (scene:scene-scale (cf:compositor-scene tinywl)))
        "and the scene converts with the same number")
    ;; A rectangle is enough to show where layout becomes device pixels: a window
    ;; needs a real shm buffer, and that is the render gate's business.
    (scene:scene-add-node (cf:compositor-scene tinywl)
                          (scene:make-rect-node 40 30 #xFF00FF00) :x 10 :y 10)
    (setf (cf:compositor-cursor-visible-p tinywl) nil)
    (cf:render-frame tinywl)
    (ok (= #xFF00FF00 (cf:frame-pixel-device tinywl 20 20))
        "the rectangle starts at device (20,20), which is layout (10,10)")
    (ok (= *background* (cf:frame-pixel-device tinywl 19 19))
        "and not one device pixel earlier")))

;;; ---------------------------------------------------------------------------
;;; Finding the parent
;;; ---------------------------------------------------------------------------

(deftest a-bare-parent-name-is-resolved-against-the-runtime-directory
  ;; WAYLAND_DISPLAY holds a *name*, and our display's socket lives in
  ;; XDG_RUNTIME_DIR.  Taking the name literally made a nested session try to
  ;; connect to a file in the current directory -- and the parity gate never saw it,
  ;; because it always passed an absolute path (the parent was in the same image).
  (let ((runtime (uiop:getenv "XDG_RUNTIME_DIR")))
    (ok (equal (format nil "~A/wayland-0" (string-right-trim "/" runtime))
               (tinywl:parent-socket-path "wayland-0"))
        "a name resolves to a path in XDG_RUNTIME_DIR")
    (ok (equal "/tmp/somewhere/wayland-7"
               (tinywl:parent-socket-path "/tmp/somewhere/wayland-7"))
        "an absolute path is already a path")
    (ok (null (tinywl:parent-socket-path nil))
        "and no name at all is NIL, which START reports as a missing parent")))

;;; ---------------------------------------------------------------------------
;;; The class seam
;;; ---------------------------------------------------------------------------

(deftest a-compositor-can-supply-its-own-class
  ;; The framework's one-line seam: MAKE-HEADLESS-COMPOSITOR builds whatever class
  ;; it is given, which is how a compositor's methods get to see its events.
  (with-tinywl (tinywl)
    (ok (typep tinywl 'tinywl:tinywl-compositor)
        "MAKE-TINYWL returns the subclass")
    (ok (typep tinywl 'cf:headless-compositor)
        "which is a headless compositor")
    (let* ((directory (make-test-directory))
           (seam (cf:make-headless-compositor
                 :width 8 :height 8
                 :display-name "tinywl-seam-0"
                 :runtime-dir directory
                 :compositor-class 'tinywl:tinywl-compositor)))
      (unwind-protect
           (ok (typep seam 'tinywl:tinywl-compositor)
               "and the class is what MAKE-HEADLESS-COMPOSITOR was asked for")
        (srv:close-display (cf:compositor-display seam))
        (ignore-errors (uiop:delete-directory-tree (pathname directory)
                                                   :validate t))))))

;;; ---------------------------------------------------------------------------
;;; The command line a VT session is asked for with
;;; ---------------------------------------------------------------------------

(deftest the-command-line-can-ask-for-a-vt
  ;; --drm is the mode; the card and the connector are names, because taking a
  ;; particular screen is a person's decision and not the default (4d-3).
  (let ((options (tinywl::parse-arguments
                  '("--drm" "--card" "/dev/dri/card9" "--connector" "Virtual-1"))))
    (ok (eq :drm (getf options :mode)) "the mode is the VT")
    (ok (string= "/dev/dri/card9" (getf options :card)) "with the card that was named")
    (ok (string= "Virtual-1" (getf options :connector)) "and the connector that was named"))
  (let ((options (tinywl::parse-arguments '("--drm"))))
    (ok (eq :drm (getf options :mode)) "a VT session with nothing else named")
    (ok (null (getf options :card)) "leaves the card to START's default")
    (ok (null (getf options :connector)) "and the connector to the card's first connected one"))
  (ok (signals (tinywl::parse-arguments '("--drm" "--card")) 'error)
      "a card option with no value is an error a person can read")
  ;; --stats is the soak's clock: a command line, because an environment variable is
  ;; what a 30-minute run forgot the first time.
  (let ((options (tinywl::parse-arguments '("--drm" "--stats" "60"))))
    (ok (= 60 (getf options :stats-interval)) "a soak can ask for a line a minute"))
  (ok (signals (tinywl::parse-arguments '("--stats" "soon")) 'error)
      "and a statistics interval that is not a number is an error"))

;;; ---------------------------------------------------------------------------
;;; The keys the kernel cannot see (a VT session)
;;; ---------------------------------------------------------------------------

(defclass recording-seat (cf.session:session)
  ((switches :initform '() :accessor seat-switches))
  (:documentation "A session whose provider records the VT it was asked for."))

(defmethod cf.session:%switch-session ((seat recording-seat) vt)
  (push vt (seat-switches seat))
  t)

(deftest a-vt-session-binds-ctrl-alt-f1-to-a-switch
  ;; libinput grabs the keyboard, so the kernel's console handler never sees
  ;; Ctrl+Alt+F1 and, seeing nothing, never switches: the compositor has to ask.  One
  ;; binding per VT, and each one asks for *its own* VT -- twelve closures over one
  ;; LOOP variable would all ask for the last.
  (with-tinywl (tinywl)
    (let ((recording (make-instance 'recording-seat :id 1 :name "seat0")))
      (tinywl:install-vt-bindings tinywl recording)
      (loop for vt from 1 to 12
            for binding = (kb:binding-for (cf:compositor-keybindings tinywl)
                                          (format nil "F~D" vt)
                                          (logior input:+modifier-control+
                                                  input:+modifier-mod1+))
            do (ok (not (null binding))
                   (format nil "Ctrl+Alt+F~D is bound: the switch is asked for, not promised" vt)))
      (labels ((fire (vt)
                 (let ((binding (kb:binding-for (cf:compositor-keybindings tinywl)
                                                (format nil "F~D" vt)
                                                (logior input:+modifier-control+
                                                        input:+modifier-mod1+))))
                   (funcall (kb:keybinding-function binding)))))
        ;; A seat that records instead of switching: libseat's own switch_session
        ;; asserts on a seat that was never opened, and an assertion in C takes the
        ;; image with it (which is why SWITCH-SESSION-TO now refuses first).
        (ok (equal '(12 1)
                   (progn (fire 1) (fire 12) (seat-switches recording)))
            "each binding asks for its own VT, not the last one the loop saw")))))

;;; ---------------------------------------------------------------------------
;;; Numbers for a soak (phase 4 exit gate, item 4)
;;; ---------------------------------------------------------------------------

(deftest a-stats-line-is-one-line-of-numbers
  (let ((line (tinywl::format-stats :uptime 60 :rss 12345 :fds 40 :frames 700
                                    :partial 690 :flips 700 :sequence 700
                                    :hotplugs 1 :resumes 2 :consed 4096 :gc 3.25)))
    (ok (search "uptime=60s" line) "uptime in seconds")
    (ok (search "rss=12345kB" line) "RSS in kilobytes")
    (ok (search "fds=40" line) "the descriptor count")
    (ok (search "frames=700 partial=690" line) "frames, and how many were partial")
    (ok (search "flips=700" line) "flips, when there is a VT output")
    (ok (search "cables=1 resumes=2" line) "and the two counters a soak watches")
    (ok (and (search "consed=4096MB" line) (search "gctime=" line))
        "allocation and collector time, so RSS can be told apart from a leak"))
  (let ((line (tinywl::format-stats :uptime 5 :rss 1 :fds 2 :frames 3 :partial 0)))
    (ok (not (search "flips" line))
        "no VT output means no flip count, rather than a zero that reads like a stop")))

(deftest the-soak-numbers-are-readable-from-proc
  (ok (plusp (tinywl::self-rss-kb)) "RSS is a positive number of kilobytes")
  (ok (plusp (tinywl::self-fd-count)) "and there is at least one descriptor open"))

(deftest a-stats-deadline-advances-once-per-interval
  (with-tinywl (tinywl)
    (let ((session (make-instance 'tinywl::session
                                  :mode :headless :compositor tinywl
                                  :stats-interval 60
                                  :started-at (get-internal-real-time))))
      (ok (zerop (tinywl::session-next-stats session)) "nothing written yet")
      (tinywl::pump-stats session)
      (ok (plusp (tinywl::session-next-stats session)) "the first call writes and arms the clock")
      (let ((deadline (tinywl::session-next-stats session)))
        (tinywl::pump-stats session)
        (ok (= deadline (tinywl::session-next-stats session))
            "a second call inside the interval writes nothing")))))

(deftest a-compositor-publishes-the-globals-a-gtk-client-binds
  ;; GDK postpones its wl_seat bind until it has seen wl_compositor *and*
  ;; wl_data_device_manager (gdkdisplay-wayland.c), so a compositor without the
  ;; data device manager gives every GTK client a window and no keyboard at all
  ;; (D64).  Emacs bound four globals and never the seat before this existed.
  (with-tinywl (tinywl)
    (let ((names (mapcar #'srv:global-interface
                         (srv:display-globals (cf:compositor-display tinywl)))))
      (ok (member "wl_compositor" names :test #'string=))
      (ok (member "wl_seat" names :test #'string=))
      (ok (member "wl_data_device_manager" names :test #'string=)
          (format nil "the data device manager is published beside the seat (~S)"
                  names)))))

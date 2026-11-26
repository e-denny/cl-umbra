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

(defmacro with-tinywl ((tinywl &key (width 512) (height 512)) &body body)
  "A tinywl compositor on a private socket, and a quiet server."
  (let ((directory (gensym "DIRECTORY")))
    `(let ((,directory (make-test-directory))
           (srv:*log-level* :warn))
       (unwind-protect
            (let ((,tinywl (tinywl:make-tinywl :width ,width :height ,height
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
  ;; The framework's headless compositor installs Alt+Esc and Alt+F1 as defaults.
  ;; A compositor whose behaviour cannot be read off its own source is one whose
  ;; bindings are somebody else's, so INSTALL-KEYBINDINGS replaces the table.
  (with-tinywl (tinywl)
    (let* ((table (cf:compositor-keybindings tinywl))
           (bindings (kb:keybinding-table-bindings table)))
      (ok (= 3 (length bindings)) "exactly three bindings")
      (ok (equal '("cycle windows" "quit" "terminal")
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

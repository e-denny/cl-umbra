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
      (ok (= 2 (length bindings)) "exactly two bindings")
      (ok (equal '("cycle windows" "quit")
                 (sort (mapcar #'kb:keybinding-description bindings) #'string<))
          "with tinywl's descriptions")
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

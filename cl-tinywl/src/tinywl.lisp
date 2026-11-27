;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; tinywl, ported (PLAN.md §5 phase 3, §7 parity checklist).
;;;;
;;;; tinywl.c is about nine hundred lines of C whose purpose is to prove that a
;;;; compositor framework works: it places a window, focuses it, moves it,
;;;; resizes it, quits.  Everything that is *machinery* in that file -- xdg-shell
;;;; state, the seat, the keymap, the scene, the renderer, the event loop -- is
;;;; the framework's here, and what is left is this file: five decisions.
;;;;
;;;; The map, function by function (§7):
;;;;
;;;;   tinywl.c                          cl-tinywl
;;;;   --------------------------------  ------------------------------------
;;;;   struct tinywl_server              TINYWL-COMPOSITOR (a CF subclass)
;;;;   wl_display_create                 CF:MAKE-HEADLESS-COMPOSITOR
;;;;   wlr_backend_autocreate            START (:headless / :nested)
;;;;   server_new_xdg_surface            CF:ON-NEW-TOPLEVEL (method below)
;;;;   xdg_toplevel_map                  CF's commit hook: focus once per map
;;;;   focus_toplevel                    FOCUS-TOPLEVEL
;;;;   desktop_toplevel_at               DESKTOP-TOPLEVEL-AT
;;;;   begin_interactive                 BEGIN-INTERACTIVE / EDGES-AT
;;;;   server_cursor_button              CF:ON-POINTER-BUTTON (method below)
;;;;   handle_keybinding                 INSTALL-KEYBINDINGS
;;;;   main                              MAIN (src/main.lisp)
;;;;
;;;; Two deliberate differences from tinywl.c, both stated where they are made:
;;;;
;;;;   1. tinywl.c has no compositor-side drag.  A move or a resize begins with a
;;;;      client's xdg_toplevel.move/.resize request -- a titlebar drag -- and that
;;;;      path is the framework's (gate clause 14).  A *reference* compositor also
;;;;      has to move a window whose client offers no titlebar, and PLAN.md §5's
;;;;      exit gate asks for it, so Alt+left drags a window and Alt+right resizes
;;;;      it from the edge under the pointer.
;;;;   2. tinywl.c places every view at (0,0) and raises it when it is focused, so
;;;;      the stack *is* the layout.  So does this.  The framework's default is a
;;;;      cascade; overriding it is the point of a port.

(in-package #:tinywl)

;;; ---------------------------------------------------------------------------
;;; The compositor
;;; ---------------------------------------------------------------------------

(defclass tinywl-compositor (cf:headless-compositor)
  ()
  (:documentation
   "A headless compositor with tinywl's policy on it.

A subclass rather than a table of hook functions, because that is how CF asks:
`on-new-toplevel' and `on-pointer-button' dispatch on the compositor, so the class
*is* the policy (D7).  It has no slots of its own on purpose -- every piece of
state tinywl.c keeps (the view list, the grabbed toplevel, the grab x/y) is the
framework's scene, grab and seat already, and a second copy is a second thing that
can disagree."))

(defun make-tinywl (&key (width 1280) (height 800) (scale 1) (background #xFF000000)
                         (display-name "wayland-0")
                         (runtime-dir (uiop:getenv "XDG_RUNTIME_DIR"))
                         (reactor nil))
  "A tinywl compositor: CF's headless compositor with tinywl's class and keys.

The display is `(cf:compositor-display ...)`; clients connect to its socket as they
would to any compositor.  DISPLAY-NAME is wayland-0 rather than the framework's
WAYLAND_DISPLAY default on purpose: a nested session needs WAYLAND_DISPLAY to name
its *parent*, and a headless session started with one must not take that socket
name."
  (let ((tinywl (cf:make-headless-compositor :width width :height height
                                             :scale scale
                                             :background background
                                             :display-name display-name
                                             :runtime-dir runtime-dir
                                             :reactor reactor
                                             :compositor-class 'tinywl-compositor)))
    (install-keybindings tinywl)
    tinywl))

;;; ---------------------------------------------------------------------------
;;; Placement
;;; ---------------------------------------------------------------------------

(defmethod cf:on-new-toplevel ((tinywl tinywl-compositor) surface)
  "Put a new window at the output's origin, on top, as tinywl.c does.

The framework's default cascades; tinywl does not place anything at all, and a
port that quietly improved on the original would make the comparison meaningless.
So the second window lands exactly on the first, and raising is the only thing
that tells them apart -- which is also what makes FOCUS-TOPLEVEL worth having."
  (let ((node (call-next-method)))
    (scene:set-node-position node 0 0)
    node))

;;; ---------------------------------------------------------------------------
;;; Focus and hit testing
;;; ---------------------------------------------------------------------------

(defun desktop-toplevel-at (tinywl x y)
  "The window at (X, Y) in output space, and the point in its own coordinates.

tinywl's `desktop_toplevel_at': the frontmost *window* under a point -- not the
cursor, which is why it takes X and Y.  A point over the bare output, or over a
surface with no shell role, is nothing, and NIL is the answer."
  (multiple-value-bind (node local-x local-y)
      (scene:scene-hit-test (cf:compositor-scene tinywl) x y)
    (when (and node (typep node 'scene:buffer-node))
      (values (scene:buffer-node-surface node) local-x local-y))))

(defun focus-toplevel (tinywl surface)
  "Raise SURFACE's window and give it the keyboard (tinywl's `focus_toplevel').

Two statements, and tinywl.c makes both: the window you chose is the window you
meant, so it comes to the front; and it is the window that hears the keyboard.  The
framework's own focus call sends the keyboard enter and the toplevel's `activated'
configure together (D27), so there is nothing to keep in sync here."
  (let ((node (and surface (cf:surface-scene-node surface))))
    (when node
      ;; A window's popups come up with it: a menu left behind over another window
      ;; is a menu for the wrong window (D44).
      (cf:raise-window-with-popups tinywl node)
      (cf:focus-surface tinywl surface)
      ;; The stack changed, so the frame changed, and no client committed anything
      ;; to say so.
      (cf:request-frame tinywl))
    surface))

;;; ---------------------------------------------------------------------------
;;; Interaction: who owns the pointer while a button is down
;;; ---------------------------------------------------------------------------

(defun parent-socket-path (name)
  "NAME -- a path or a bare WAYLAND_DISPLAY name -- resolved to a socket path.

A compositor's own display is named (\"wayland-0\") and lives in XDG_RUNTIME_DIR, so a
nested session that took WAYLAND_DISPLAY literally would try to connect to a file in
the current directory.  The rule is WAYLAND.IO:SOCKET-PATH's, because the server
creates the socket this has to find; duplicating it here is how the two drift."
  (when name
    (wayland.io:socket-path :display-name name)))

(defparameter +resize-margin+ 12
  "How close to a window's side a press must be for that side to resize it.

tinywl.c has no margin to choose: every resize begins at the edge the *client*
asked for.  A compositor that decides for itself needs a rule, and twelve pixels is
small enough to reach the middle by aim and large enough to hit a corner with a
mouse.")

(defun pointer-reach (node)
  "The window's interactive rectangle in output space: (values left top width height).

The sides a person can aim at are the sides that take input.  A client with
client-side decorations sets an input region that excludes its shadow -- weston-terminal's
is (32 32 742 499) inside an 806x563 surface -- so the *visible* left border is 32 pixels
in from the surface's bounding box.  Measuring the grab margin from the bounding box put
that border outside it, and a press on the visible border then read as 'the body of the
window' and resized from the bottom-right: the right and bottom edges moved and the one
under the pointer did not (the sixth manual test).  A surface with no input region is its
own reach, which is every client that does not decorate itself."
  (let* ((surface (and (typep node 'scene:buffer-node) (scene:buffer-node-surface node)))
         (region (and surface (srv:surface-input-region surface))))
    (if (and (consp region) (plusp (length region)))
        (let ((x0 (loop for (x y w h) in region minimize x))
              (y0 (loop for (x y w h) in region minimize y))
              (x1 (loop for (x y w h) in region maximize (+ x w)))
              (y1 (loop for (x y w h) in region maximize (+ y h))))
          (declare (ignorable x0))   ; silence an unused-binding warning in some builds
          (values (+ (scene:node-x node) x0)
                  (+ (scene:node-y node) y0)
                  (max 1 (- x1 x0))
                  (max 1 (- y1 y0))))
        (values (scene:node-x node) (scene:node-y node)
                (scene:node-width node) (scene:node-height node)))))

(defun edges-at (node x y)
  "The resize edges a press at (X, Y) asks for, as an xdg_toplevel.resize_edge mask.

The sides within `+resize-margin+' of the point win; a point in the body of the
window means its bottom-right corner, because that is the corner a person drags
when the window has no border to grab.  The rectangle those sides come from is the
one the pointer can reach (POINTER-REACH), not the surface's bounding box, so a
client's own border is a border and not a body."
  (multiple-value-bind (left top width height) (pointer-reach node)
    (let* ((local-x (- x left))
           (local-y (- y top))
           (edges 0))
      (when (< local-x +resize-margin+)
      (setf edges (logior edges grab:+edge-left+)))
      (when (< local-y +resize-margin+)
        (setf edges (logior edges grab:+edge-top+)))
      (when (> local-x (- width +resize-margin+))
        (setf edges (logior edges grab:+edge-right+)))
      (when (> local-y (- height +resize-margin+))
        (setf edges (logior edges grab:+edge-bottom+)))
      (if (zerop edges)
          (logior grab:+edge-right+ grab:+edge-bottom+)
          edges))))

(defun begin-interactive (tinywl surface mode)
  "Start tinywl's interactive MODE (:move or :resize) on SURFACE.

tinywl.c keeps a `cursor_mode' enum and three grabbed values (the toplevel, the
grab x/y and its geometry); here the interaction is a cf.grab object that the
framework ends and that knows how to move a node or ask for a size.  The button in
the grab is the one physically down, so the drag ends on the button that started
it and not on some other click during it."
  (let* ((node (cf:surface-scene-node surface))
         (x (cf:compositor-cursor-x tinywl))
         (y (cf:compositor-cursor-y tinywl))
         (button (if (eq mode :move) #x110 #x111)))
    (when node
      (ecase mode
        (:move
         (cf:start-grab tinywl (grab:begin-move-grab node x y :button button
                                                     :output-width (cf:compositor-width tinywl)
                                                     :output-height (cf:compositor-height tinywl))))
        (:resize
         (cf:start-grab tinywl (grab:begin-resize-grab node x y
                                                       (edges-at node x y)
                                                       :button button
                                                       ;; A resize stops at the output's
                                                       ;; edge, as a move does (D46).
                                                       :output-width (cf:compositor-width tinywl)
                                                       :output-height (cf:compositor-height tinywl)))))
      t)))

(defun alt-held-p (tinywl)
  "Is Alt down, according to the modifier state the key path maintains?"
  (logtest input:+modifier-mod1+
           (input:modifiers-depressed (cf:compositor-modifiers tinywl))))

(defmethod cf:on-pointer-button ((tinywl tinywl-compositor) button state)
  "Alt+left moves, Alt+right resizes, any other press focuses and is a click.

A press that starts a drag is **not** forwarded to the client: the grab owns the
pointer from then on, and a client that never saw a press must not see its release
-- the same rule the framework applies to a key a binding consumed.  That is also
what keeps a drag from becoming a click on a titlebar-less window.

The second clause is tinywl's own `server_cursor_button': the press focuses the
window under the pointer (the framework does that, before it sends the button) and
*raises* it, which the framework does not, because a framework cannot know whether
its compositor wants click-to-raise."
  (cond
    ((and (eq state :pressed)
          (member button '(:left :right))
          (alt-held-p tinywl))
     (multiple-value-bind (surface x y)
         (desktop-toplevel-at tinywl (cf:compositor-cursor-x tinywl)
                                     (cf:compositor-cursor-y tinywl))
       (declare (ignore x y))
       (if surface
           (progn
             (focus-toplevel tinywl surface)
             (begin-interactive tinywl surface (if (eq button :left) :move :resize)))
           ;; Alt over the bare output is not a drag: there is nothing to move, and
           ;; swallowing the press would make the output a dead zone.
           nil)))
    (t
     (prog1 (call-next-method)
       (when (eq state :pressed)
         (multiple-value-bind (surface x y)
             (desktop-toplevel-at tinywl (cf:compositor-cursor-x tinywl)
                                         (cf:compositor-cursor-y tinywl))
           (declare (ignore x y))
           (let ((node (and surface (cf:surface-scene-node surface))))
             (when node
               (cf:raise-window-with-popups tinywl node)
               (cf:request-frame tinywl)))))))))

;;; ---------------------------------------------------------------------------
;;; Starting a client
;;; ---------------------------------------------------------------------------
;;
;; A compositor that cannot start anything is a compositor you look at.  tinywl.c has
;; no launcher (you start clients against it from elsewhere), but a nested session is
;; exactly the case where that is awkward: the environment's WAYLAND_DISPLAY names the
;; *parent*, so a client started from the shell lands outside the window you meant.

(defparameter *terminal-command* '("weston-terminal")
  "What Alt+Shift+Return starts.

weston-terminal by default because it is the terminal that works on a renderer this
small: it is toytoolkit over wl_shm, no EGL, no X.  kitty needs an EGL surface and
xterm needs XWayland, so neither can appear here yet; foot, alacritty and the like
work if they are installed and use shm.  Change this from the REPL -- it is a normal
special variable, and the running image is this compositor's control surface (D14).")

(defvar *clients* '()
  "Processes LAUNCH started, newest first, so they can be stopped with the session.")

(defun launch (tinywl &key (command *terminal-command*))
  "Start COMMAND as a client of THIS compositor's own display.

The child inherits our environment with one thing changed: WAYLAND_DISPLAY is our
socket, because in a nested session the environment names the parent and a client
started against the parent would appear outside the window it was asked for.  The
exec goes through /bin/sh so HOME, PATH, TERM and the locale survive -- passing
:environment to RUN-PROGRAM would replace all of it, and a terminal with no HOME is
a terminal that cannot read its own config."
  (let* ((display (cf:compositor-display tinywl))
         (socket (srv:display-socket-path display))
         (name (pathname-name (pathname socket)))
         (process
           (handler-case
               (sb-ext:run-program
                "/bin/sh"
                (append (list "-c"
                              "WAYLAND_DISPLAY=$1; export WAYLAND_DISPLAY; shift; exec \"$@\""
                              "tinywl-launch" name)
                        command)
                ;; The child's diagnostics come back to whoever is watching this
                ;; compositor: a launcher that swallows "cannot connect" is a
                ;; launcher whose failures look like nothing happening.
                :wait nil :search t :error *error-output*)
             (error (condition)
               (srv:log-message :warn "could not start ~S: ~A" (first command) condition)
               nil))))
    (when process
      (srv:log-message :info "started ~S (pid ~D) on ~A"
                       (first command) (sb-ext:process-pid process) name)
      (push process *clients*))
    process))

(defun stop-clients ()
  "Stop the clients LAUNCH started; they have already been told goodbye.

Called from STOP after the display is closed, so a client that honours EOF has
already gone; a client that does not is asked with SIGTERM rather than left behind."
  (dolist (process *clients*)
    (when (sb-ext:process-alive-p process)
      (ignore-errors (sb-ext:process-kill process 15)))
    (ignore-errors (sb-ext:process-close process)))
  (setf *clients* '()))

;;; ---------------------------------------------------------------------------
;;; Keybindings
;;; ---------------------------------------------------------------------------

(defun close-toplevels (tinywl)
  "Ask every mapped window to close (xdg_toplevel.close); return how many.

tinywl.c simply terminates, and every client finds its socket closed.  Asking
first is one extra request and the difference between a session that ends and a
session that is cut off: a client that handles `close' flushes what it was doing
and exits by itself."
  (let ((count 0))
    (dolist (client (srv:display-clients (cf:compositor-display tinywl)))
      (dolist (resource (srv:client-resources client))
        (when (and (typep resource 'srv:xdg-toplevel)
                   (srv:xdg-toplevel-mapped-p resource))
          (srv:close-toplevel resource)
          (incf count))))
    count))

(defun install-keybindings (tinywl)
  "tinywl's bindings: Alt+Esc quits, Alt+Tab opens the switcher, Alt+F1 cycles the
windows, Alt+Shift+Return starts a terminal.

The framework installs Alt+Esc, Alt+Tab and Alt+F1 on a headless compositor as its
defaults, and this replaces the table rather than adding to it -- deliberately.  A
compositor's keymap is a statement about that compositor, and one that inherits a
binding it did not choose is one whose behaviour cannot be read off its own source.

Alt+Tab is an addition to tinywl.c, not a port of it: tinywl.c has no focus stack at
all (it raises the window it is told to focus and forgets the rest), and the stack is
the framework's (D45).  The binding opens the *visible* switcher (D51) rather than
calling FOCUS-STACK-CYCLE directly: one tap and release still lands on the same
window, because the overlay's first row is what the cycle would have chosen -- what
changes is that a person can see it.  Alt+Shift+Tab opens it one row back, on the
window that has the keys now.  Alt+F1 stays tinywl's own rule -- the bottom window
*in draw order* comes to the top -- because a port that quietly replaced it would
make the parity script meaningless."
  (setf (cf:compositor-keybindings tinywl) (kb:make-keybinding-table))
  (cf:add-keybinding tinywl "Escape"
                     (lambda ()
                       (close-toplevels tinywl)
                       (cf:stop-compositor tinywl))
                     :modifiers input:+modifier-mod1+
                     :description "quit")
  (cf:add-keybinding tinywl "Tab"
                     (lambda () (cf:start-switcher tinywl))
                     :modifiers input:+modifier-mod1+
                     :description "switcher")
  (cf:add-keybinding tinywl "Tab"
                     (lambda () (cf:start-switcher tinywl :step -1))
                     :modifiers (logior input:+modifier-mod1+ input:+modifier-shift+)
                     :description "switcher backwards")
  (cf:add-keybinding tinywl "F1"
                     (lambda () (cf:cycle-views tinywl))
                     :modifiers input:+modifier-mod1+
                     :description "cycle windows")
  ;; Mod1+Shift+Return rather than Mod1+Return: the latter is every compositor's
  ;; "open a terminal", so a parent session would take the key before we saw it.
  (cf:add-keybinding tinywl "Return"
                     (lambda () (launch tinywl))
                     :modifiers (logior input:+modifier-mod1+ input:+modifier-shift+)
                     :description "terminal")
  tinywl)

;;; ---------------------------------------------------------------------------
;;; A session
;;; ---------------------------------------------------------------------------
;;
;; "Backend" in the framework means "where the pixels go and where the input comes
;; from"; tinywl's two choices are a target in memory with injected input (:headless)
;; and an output inside another compositor (:nested).  Both are sessions here, so a
;; caller -- main, or the parity gate -- drives one the same way whatever is behind
;; it.

(defclass session ()
  ((mode :initarg :mode :reader session-mode)
   (compositor :initarg :compositor :reader session-compositor)
   (nested :initarg :nested :initform nil :reader session-nested)
   ;; The two things a VT session owns and the other two do not: the seat, and the
   ;; card the seat hands out.  A compositor that keeps these alive is a compositor
   ;; that gives the screen back on the way out, which is the whole of 4d-3.
   (vt-output :initarg :vt-output :initform nil :reader session-vt-output)
   (seat :initarg :seat :initform nil :reader session-seat))
  (:documentation
   "A running tinywl: its compositor, and the backend behind it -- nested, or a VT."))

(defmethod print-object ((session session) stream)
  (print-unreadable-object (session stream :type t)
    (format stream "~A on ~A"
            (string-downcase (symbol-name (session-mode session)))
            (srv:display-socket-path
             (cf:compositor-display (session-compositor session))))))

(defun start (&key (mode :headless)
                   width height (scale 1)
                   (background #xFF000000)
                   display-name
                   runtime-dir
                   parent-path
                   launch
                   pump
                   (card "/dev/dri/card0") connector crtc-id
                   (seat-name "seat0"))
  "Start tinywl and return its SESSION.

:headless renders into memory and takes input only from CF:INJECT-*; :nested renders
into a window of the compositor at PARENT-PATH (default: WAYLAND_DISPLAY) and takes
input from that compositor's seat.  DISPLAY-NAME defaults to \"wayland-0\" for a
headless session -- it is the only compositor on that runtime directory -- and
\"tinywl-1\" nested, where the parent already owns a socket.  PUMP is the nested
case's escape hatch for a parent in the same image (see CF.BACKEND.NESTED).
When the parent's socket is not there, that is an error worth reporting before a
window appears.

SCALE is device pixels per layout coordinate: 2 makes the session render at the
density of a HiDPI output (crisp text, twice the buffer), 1 is the old behaviour.
A nested session tells the parent the same scale, so the parent still gives it the
layout size it asked for (D49)."
  (ecase mode
    (:headless
     (let ((tinywl (make-tinywl
                    :width (or width 1280) :height (or height 800) :scale scale
                    :background background
                    :display-name (or display-name "wayland-0")
                    :runtime-dir (or runtime-dir (uiop:getenv "XDG_RUNTIME_DIR")))))
       (when launch (launch tinywl :command launch))
       (make-instance 'session :mode :headless :compositor tinywl)))
    (:nested
     (let* ((parent (parent-socket-path (or parent-path (uiop:getenv "WAYLAND_DISPLAY"))))
            (backend (progn
                       (unless parent
                         (error "a nested session needs a parent: --parent PATH, or ~
WAYLAND_DISPLAY in the environment"))
                       (nested:start-nested
                        :parent-path parent
                        :width (or width 1280) :height (or height 800)
                        :scale scale
                        :display-name (or display-name "tinywl-1")
                        :runtime-dir (or runtime-dir
                                         (uiop:getenv "XDG_RUNTIME_DIR"))
                        ;; The nested session's policy is this compositor's
                        ;; policy: the class goes through, so a parent pointer
                        ;; press lands in TINYWL-COMPOSITOR's ON-POINTER-BUTTON.
                        :compositor-class 'tinywl-compositor
                        :pump pump))))
       (install-keybindings (nested:nested-compositor backend))
       (when launch
         (launch (nested:nested-compositor backend) :command launch))
       (make-instance 'session
                      :mode :nested
                      :compositor (nested:nested-compositor backend)
                      :nested backend)))
    (:drm
     (start-vt :width width :height height :scale scale :background background
               :display-name display-name :runtime-dir runtime-dir
               :launch launch :card card :connector connector :crtc-id crtc-id
               :seat-name seat-name))))

(defun start-vt (&key width height (scale 1) (background #xFF000000)
                     display-name runtime-dir launch
                     (card "/dev/dri/card0") connector crtc-id (seat-name "seat0"))
  "Start tinywl on a VT: a seat, the card it hands out, and a compositor on it.

This is 4d-3's join, and the order is the constraint: the seat comes first (the
provider enables it inside the open call), the card comes from the seat, and only
then is there a mode to build a compositor at.  A compositor's width and height are
layout coordinates, so a card programmed at 1920x1080 with SCALE 2 is a 960x540
compositor drawing on a 1920x1080 screen (D49).

The compositor renders through the output's frame hooks (CF.BACKEND.VT): the
preparer answers a target over the scanout buffer, the presenter flips it and waits
for vblank.  A seat enable after a VT switch asks for a frame, because the screen
came back blank and the compositor has to say what is on it again."
  (let* ((seat (handler-case (seat:open-session :name seat-name)
                 (seat:session-error (condition)
                   ;; The one failure a person will hit first, and the one whose
                   ;; errno means nothing on its own: libseat answers with the last
                   ;; backend's errno, and ENOSYS here means "somebody else owns this
                   ;; session" (D56 §4).
                   (error "a VT session needs a seat this user may take, and this
one was refused (~A): run tinywl --drm from a text console, not from inside a
compositor that already owns the screen"
                          condition))))
         (output nil)
         (tinywl nil))
    (handler-case
        (progn
          (setf output (vt:open-vt-output seat :path card :connector connector
                                                    :crtc-id crtc-id))
          ;; A seat that opened but is not enabled yet is a seat with no card, and a
          ;; compositor built from a zero-size output is a 1x1 screen.  Say so.
          (unless (vt:vt-output-enabled-p output)
            (error "the seat opened but is not enabled yet (state ~A): a VT session
needs a seat that is usable now, which is what dispatch inside OPEN-SESSION is for"
                   (seat:session-state-string seat)))
          (let* ((device-width (vt:vt-output-width output))
                 (device-height (vt:vt-output-height output))
                 (layout-width (or width (max 1 (floor device-width scale))))
                 (layout-height (or height (max 1 (floor device-height scale)))))
            (setf tinywl
                  (make-tinywl :width layout-width :height layout-height
                               :scale scale :background background
                               :display-name (or display-name "wayland-0")
                               :runtime-dir (or runtime-dir
                                                (uiop:getenv "XDG_RUNTIME_DIR"))))
            (multiple-value-bind (preparer presenter) (vt:make-vt-frame-hooks output)
              (setf (headless:compositor-frame-preparer tinywl) preparer
                    (headless:compositor-frame-presenter tinywl) presenter))
            ;; A VT switch back is a screen that must be redrawn, and the seat's
            ;; hook is the only thing that knows it happened.
            (seat:add-session-enable-hook
             seat (lambda (session)
                    (declare (ignore session))
                    (cf:request-frame tinywl)))
            (install-stop-signals tinywl)
            (cf:request-frame tinywl))
          (when launch (launch tinywl :command launch))
          (make-instance 'session :mode :drm :compositor tinywl
                                  :vt-output output :seat seat))
      (error (condition)
        ;; A half-started VT session holds the screen: give it back before the error
        ;; reaches the person who typed the command.
        (when output (ignore-errors (vt:close-vt-output output)))
        (ignore-errors (seat:close-session seat))
        (error condition)))))

(defun install-stop-signals (tinywl)
  "Stop cleanly on SIGINT, SIGTERM and SIGHUP, so the screen is always given back.

The handler runs inside a reactor cycle (REACTOR:ADD-SIGNAL-HANDLER posts rather
than acts in the signal), which is what makes it safe to do more than set a flag:
the reactor stops, RUN returns, and the caller's UNWIND-PROTECT restores the CRTC
and closes the seat.  A compositor killed outright cannot restore anything, which
is why the interactive quit (Alt+Esc) and these three signals are the only ways out."
  (reactor:add-signal-handler
   (srv:display-reactor (cf:compositor-display tinywl))
   (list ffi:+sigint+ ffi:+sigterm+ ffi:+sighup+)
   :on-signal (lambda (message signal)
                (declare (ignore message))
                (srv:log-message :info "tinywl: signal ~D, giving the screen back"
                                 signal)
                (cf:stop-compositor tinywl))))

(defun advance (session &key (timeout 0.01))
  "Advance SESSION one cycle and return it.

One cycle is: the parent connection (nested only), then our own display.  A caller
that owns a second loop -- a test, a gate, another compositor -- calls this in its
own loop; `run' is the loop for a session on its own."
  (let ((nested (session-nested session))
        (seat (session-seat session)))
    (cond
      (nested (nested:nested-dispatch nested :timeout timeout))
      (t
       ;; The seat first: an enable or disable callback applies to this cycle's
       ;; frame, and a display cycle that ran first would draw a frame for a screen
       ;; the provider has already taken away.
       (when seat
         (seat:dispatch-session seat :timeout 0))
       (srv:run-once (cf:compositor-display (session-compositor session))
                     :timeout timeout))))
  session)

(defun run (session &key (timeout 0.05))
  "Run SESSION until it stops: Alt+Esc, a client closing the nested window, or the
parent going away."
  (let ((reactor (srv:display-reactor
                  (cf:compositor-display (session-compositor session))))
        (nested (session-nested session)))
    (loop until (or (reactor:stopped-p reactor)
                    (and nested (nested:nested-closing-p nested)))
          do (advance session :timeout timeout))
    session))

(defun stop (session)
  "Tear SESSION down; idempotent.

A nested session destroys its parent-side window first, so the parent unmaps a
window instead of noticing a dead socket, then its own buffers and display.  A
headless session just closes its display, which is what tells the clients.  The
second call does nothing: stopping a compositor twice must not be an error, because
both a signal handler and the caller's UNWIND-PROTECT can reach this."
  (let ((nested (session-nested session))
        (compositor (session-compositor session))
        (vt-output (session-vt-output session))
        (seat (session-seat session)))
    ;; The screen goes back first, while the descriptor, the buffers and the
    ;; CRTC's saved state are all still here.  Closing the display first would only
    ;; work because nothing else fails; this order is the one that is true.
    (when vt-output
      (ignore-errors (vt:close-vt-output vt-output)))
    (when seat
      (ignore-errors (seat:close-session seat)))
    (cond
      (nested (nested:stop-nested nested))
      ((not (srv:display-closed-p (cf:compositor-display compositor)))
       (cf:stop-compositor compositor)
       (ignore-errors
         (srv:close-display (cf:compositor-display compositor)))))
    (stop-clients))
  session)

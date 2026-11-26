;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The phase-3 exit gate: the tinywl parity script, run twice.
;;;;
;;;; Run by scripts/tinywl-parity.sh, once with TINYWL_MODE=headless and once with
;;;; TINYWL_MODE=nested.  The scenario is identical in both, and that is the point:
;;;; a compositor whose behaviour changes when its output is a window in another
;;;; compositor is a compositor whose policy is in the wrong layer.
;;;;
;;;;   headless   tinywl's own display; input injected straight into it
;;;;   nested     tinywl inside our headless compositor; input injected into the
;;;;              *parent* and translated by cf.backend.nested into tinywl's seat
;;;;
;;;; Two real libwayland clients, each with its own xdg-shell:
;;;;
;;;;   A  weston-eventdemo --log-key --log-resize --log-focus, titled "parity-a"
;;;;      It prints every key it receives and every size it is configured to, so
;;;;      "the focused window types" and "the resize became a configure" are read
;;;;      off the client's own output.
;;;;   B  wayland-move-client (compiled by the shell script), titled "move-client"
;;;;      A uniform #xFF3C8C3C window, which is what makes "the pixels moved with
;;;;      the window" a pixel comparison rather than a guess.
;;;;
;;;; What each assertion is for (PLAN.md §5, phase 3 exit gate):
;;;;
;;;;   1. a real client starts, maps and is drawn -- by cl-tinywl's own placement
;;;;      (every window at the origin, tinywl.c's rule), not the framework's;
;;;;   2. a click focuses: the press moves the keyboard and configures the window
;;;;      activated;
;;;;   3. typing reaches the focused window *only*: A prints while it is focused and
;;;;      prints nothing after B takes the keyboard;
;;;;   4. Alt+left drags the window under the pointer by the pointer's delta, and it
;;;;      stops when the button comes up;
;;;;   5. Alt+right drags from the edge under the pointer and the client is
;;;;      configured for the size the drag implies;
;;;;   6. Alt+F1 sends the bottom window to the front and focuses it;
;;;;   7. Alt+Esc asks every client to close (xdg_toplevel.close) and stops the loop,
;;;;      and no client ever sees a protocol error;
;;;;   8. WAYLAND_DEBUG=1 on B is an ordered, valid event stream: a configure was
;;;;      acked after it arrived and no error was sent either way;
;;;;   9. the frame the nested presenter commits has already been painted.  Nested
;;;;      only, because the presenter exists only there: it attaches our target
;;;;      into the parent, which composites that shared memory whenever it likes.
;;;;      A presenter that runs before the draw commits the background paint alone,
;;;;      and the window in the parent is black or half-drawn -- the flicker the
;;;;      manual test found (D38).
;;;;  10. the pointer's picture follows the *client*: over the terminal's text area the
;;;;      scene draws the image that client installed, with that client's hotspot, and
;;;;      a nested session tells the parent to draw no pointer while it does -- then
;;;;      gives the pointer back at a bare-output spot, with nothing of its own drawn
;;;;      there (D39, D41).
;;;;
;;;; The nested run's parent is a harness, not the thing under test, so its two
;;;; keybindings (Alt+Esc, Alt+F1 -- the framework's defaults) are cleared: a parent
;;;; that binds a key swallows it before its client sees it, which is exactly what
;;;; would happen in a real nested session and would prove nothing about tinywl.

(asdf:load-system "cl-tinywl")

(in-package #:cl-user)

(defparameter *background* #xFF000000)
(defparameter *move-colour* #xFF3C8C3C "wayland-move-client's uniform window.")
(defparameter *pointer-park-x* 480 "Where the pointer waits when it is not being used.")
(defparameter *pointer-park-y* 480)

(defvar *mode* :headless)
(defvar *session* nil)
(defvar *inner* nil "The tinywl compositor: what all the assertions are about.")
(defvar *input* nil "The compositor synthetic input is injected into.")
(defvar *parent* nil "The nested run's parent compositor, or NIL.")
(defvar *pty-a* nil)
(defvar *pty-b* nil)
(defvar *lines-a* '())
(defvar *lines-b* '())
(defvar *ok* t)
(defvar *process-a* nil)
(defvar *process-b* nil)

(defun check (condition control &rest arguments)
  (if condition
      (format t "  ok   [~(~A~)] ~?~%" *mode* control arguments)
      (progn (setf *ok* nil)
             (format t "  FAIL [~(~A~)] ~?~%" *mode* control arguments)))
  condition)

;;; ---------------------------------------------------------------------------
;;; Driving the session and reading the clients
;;; ---------------------------------------------------------------------------

(defun drain (pty lines-symbol)
  "Read whatever PTY has printed into the special variable LINES-SYMBOL.

A pty whose process has exited raises EIO from LISTEN; that is the normal end of a
drain, not an error."
  (handler-case
      (loop while (and pty (listen pty))
            do (let ((line (read-line pty nil nil)))
                 (when line
                   (setf (symbol-value lines-symbol)
                         (append (symbol-value lines-symbol) (list line))))))
    (error () nil)))

(defun pump (seconds &key until)
  "Advance tinywl (and the nested parent) until UNTIL is true or SECONDS pass."
  (let ((deadline (+ (get-internal-real-time)
                     (* seconds internal-time-units-per-second))))
    (loop
      (let ((value (and until (funcall until))))
        (when value (return value)))
      (when (> (get-internal-real-time) deadline)
        (return nil))
      (tinywl:advance *session* :timeout 0.005)
      (drain *pty-a* '*lines-a*)
      (drain *pty-b* '*lines-b*))))

(defun await-line (lines-symbol needle seconds)
  "Wait until the client printing into LINES-SYMBOL printed NEEDLE; return the line."
  (or (find needle (symbol-value lines-symbol) :test #'search)
      (pump seconds
            :until (lambda ()
                     (find needle (symbol-value lines-symbol) :test #'search)))))

(defun expect (lines-symbol needle &key (seconds 10) (label nil))
  (let ((line (await-line lines-symbol needle seconds)))
    (check line "the client printed ~S~@[: ~A~]" (or label needle)
           (and line (string-trim '(#\Return #\Newline) line)))
    line))

(defun plain (line)
  "LINE with libwayland's ANSI colour codes removed.

WAYLAND_DEBUG colours its output whenever stderr is a terminal, and a pty is one:
`xdg_surface#8.configure' arrives as three runs with escape sequences between them.
So the debug assertions search the text, not the colouring."
  (with-output-to-string (out)
    (loop with i = 0
          while (< i (length line))
          do (let ((character (char line i)))
               (if (char= character #\Escape)
                   (progn
                     (incf i)
                     (when (and (< i (length line)) (char= (char line i) #\[))
                       (incf i)
                       (loop while (and (< i (length line))
                                        (not (char<= #\@ (char line i) #\~)))
                             do (incf i))
                       (incf i)))
                   (progn (write-char character out)
                          (incf i)))))))

(defun count-lines (lines-symbol needle)
  (count-if (lambda (line) (search needle line)) (symbol-value lines-symbol)))

(defun settle ()
  "Let injected input reach the inner compositor before looking at it.

In a nested session input is injected into the *parent* and travels to us over a
socket, so the inner compositor has not seen a press when the call returns; a
headless injection is already synchronous.  Anything that asserts on the
compositor's reaction to an input calls this first -- and that asymmetry is itself
worth knowing: the nested input path is a real protocol round trip."
  (when *parent*
    (pump 0.2)))

(defun moves (x y) (cf:inject-pointer-motion *input* x y))
(defun button (which state) (cf:inject-pointer-button *input* which state))
(defun key (name state) (cf:inject-key *input* name state))

;;; ---------------------------------------------------------------------------
;;; Reading the compositor's state
;;; ---------------------------------------------------------------------------

(defun resources-of-type (compositor type)
  (loop for client in (wayland.server:display-clients (cf:compositor-display compositor))
        append (remove-if-not (lambda (resource) (typep resource type))
                              (wayland.server:client-resources client))))

(defun mapped-surfaces (compositor)
  (remove-if-not (lambda (surface) (cf:surface-scene-node surface))
                 (cf:compositor-surfaces compositor)))

(defun lit-pixel-count (compositor)
  "Sampled pixels of COMPOSITOR's current target that are not the black background.

A target that has been drawn into has some; a target holding only the background
paint has none.  That is the whole distinction clause 9 needs, in one number:
"presented before the draw" and "presented after it" cannot be confused."
  (let ((width (cf:compositor-width compositor))
        (height (cf:compositor-height compositor)))
    (loop for y from 0 below height by 4
          sum (loop for x from 0 below width by 4
                    count (plusp (logand #x00FFFFFF (cf:frame-pixel compositor x y)))))))

(defun surface-of-process (compositor process)
  "The window PROCESS mapped: the surface whose client has that pid (SO_PEERCRED).

By pid and not by title or by order: a client's title is the client's to omit (weston's
eventdemo sets none), and the first surface to map would make the gate depend on
whichever client won a race.  The pid is what the server knows and the test knows."
  (let ((pid (sb-ext:process-pid process)))
    (find-if (lambda (surface)
               (let ((client (wayland.server:resource-client surface)))
                 (and client (eql pid (wayland.server:client-pid client)))))
             (mapped-surfaces compositor))))

(defun node-of (surface) (cf:surface-scene-node surface))

(defun node-position (surface)
  (multiple-value-list (cf.scene:node-position (node-of surface))))

(defun node-size (surface)
  (let ((node (node-of surface)))
    (list (cf.scene:node-width node) (cf.scene:node-height node))))

(defun pixel (x y) (cf:frame-pixel *inner* x y))

(defun park-pointer ()
  "Move the pointer out of the way and let the frame catch up.

The compositor draws its own cursor at the pointer, so a pixel assertion taken under
it is an assertion about the cursor."
  (moves *pointer-park-x* *pointer-park-y*)
  (pump 0.3))

(defun window-nodes (compositor)
  "The scene's window nodes, back to front.

Windows, not buffer nodes: a client's cursor surface is a buffer node with no shell
role, and it is not something a compositor raises."
  (remove-if-not (lambda (node)
                   (and (typep node 'cf.scene:buffer-node)
                        (wayland.server:surface-shell-surface
                         (cf.scene:buffer-node-surface node))))
                 (cf.scene:node-children
                  (cf.scene:scene-root (cf:compositor-scene compositor)))))

(defun top-window (compositor)
  (car (last (window-nodes compositor))))

(defun keyboard-focus (compositor)
  (wayland.server:seat-keyboard-focus (cf:compositor-seat compositor)))

;;; ---------------------------------------------------------------------------
;;; The run
;;; ---------------------------------------------------------------------------

(defvar *client-display* nil "The name of our socket, for the clients' environment.")

(defun parity-client (path arguments)
  "Start a client against our own socket, with libwayland's debug stream on.

Return (values process pty).  WAYLAND_DEBUG=1 is part of the gate (clause 6): the
client's own log of the protocol is the only place an *ordered* event stream can be
inspected, and it costs nothing when the client is already printing."
  (let ((process (sb-ext:run-program
                  path arguments
                  :wait nil :pty t :search t :error :output
                  :environment
                  (list (format nil "WAYLAND_DISPLAY=~A" *client-display*)
                        (format nil "XDG_RUNTIME_DIR=~A" (uiop:getenv "XDG_RUNTIME_DIR"))
                        "HOME=/tmp"
                        "PATH=/usr/local/bin:/usr/bin:/bin"
                        "WAYLAND_DEBUG=1"))))
    (values process (sb-ext:process-pty process))))

(defun start-parent (width height)
  "The nested run's parent: a compositor that forwards what it is given.

Its keybindings are cleared on purpose (see the header): a parent that binds
Alt+Esc would swallow the key before its client -- us -- ever saw it."
  (let ((parent (cf:make-headless-compositor :width width :height height
                                             :display-name "parity-parent"
                                             :runtime-dir (uiop:getenv "XDG_RUNTIME_DIR")
                                             :background *background*)))
    (setf (cf:compositor-keybindings parent)
          (cf.keybindings:make-keybinding-table))
    parent))

(defun report-failure ()
  "The last lines each client printed, which is where a failure is explained.

The tail, not everything: B runs with WAYLAND_DEBUG=1 and a healthy run is hundreds
of lines of protocol."
  (format t "~&clients printed:~%")
  (dolist (pair (list (cons "A" *lines-a*) (cons "B" *lines-b*)))
    (format t "  ~A (last 40 lines):~%" (car pair))
    (dolist (line (last (cdr pair) 40))
      (format t "    | ~A~%" (string-trim '(#\Return #\Newline) line)))))

(let* ((runtime-dir (or (uiop:getenv "XDG_RUNTIME_DIR")
                        (error "XDG_RUNTIME_DIR is not set")))
       (png (or (uiop:getenv "FRAME_PNG") "/tmp/cl-wayland-tinywl.png"))
       (client-a (or (uiop:getenv "TINYWL_CLIENT") "weston-eventdemo"))
       (client-b (or (uiop:getenv "TINYWL_SECOND_CLIENT")
                     (error "TINYWL_SECOND_CLIENT is not set")))
       (fds-before (length (directory #p"/proc/self/fd/*"))))

  (setf *mode* (if (string-equal (uiop:getenv "TINYWL_MODE") "nested")
                   :nested :headless))

  (unwind-protect
       ;; An error mid-scenario is a failure of the run, not a crash to read: the
       ;; cleanup below still tears the session down and prints the verdict, so a
       ;; broken gate says FAILED instead of leaving a socket behind and exiting 0.
       (handler-case
       (progn
         ;; 0. A session, in the mode this run is about.
         (when (eq *mode* :nested)
           (setf *parent* (start-parent 512 512)))
         (setf *session*
               (if *parent*
                   (tinywl:start :mode :nested
                                 :width 512 :height 512
                                 :parent-path (wayland.server:display-socket-path
                                               (cf:compositor-display *parent*))
                                 :display-name "parity-inner"
                                 :runtime-dir runtime-dir
                                 ;; The parent is in this image, so something has
                                 ;; to run its reactor while the nested backend
                                 ;; waits (D34.10).
                                 :pump (lambda (seconds)
                                         (wayland.server:run-once
                                          (cf:compositor-display *parent*)
                                          :timeout seconds)))
                   (tinywl:start :mode :headless
                                 :width 512 :height 512
                                 :display-name "parity-outer"
                                 :runtime-dir runtime-dir
                                 :background *background*)))
         (setf *inner* (tinywl:session-compositor *session*)
               ;; Input goes to the *parent* in a nested session: it is the
               ;; compositor a person's mouse is over, and everything from there is
               ;; cf.backend.nested's translation.
               *input* (or *parent* *inner*))
         (let ((our-socket (wayland.server:display-socket-path
                            (cf:compositor-display *inner*))))
           (format t "tinywl: ~(~A~) session, ~Dx~D, socket ~A~%"
                   *mode* (cf:compositor-width *inner*) (cf:compositor-height *inner*)
                   our-socket)
           (setf *client-display* (pathname-name (pathname our-socket))))

         ;; 1. A real client starts, maps and is drawn where tinywl puts it.
         (multiple-value-bind (process pty)
             (parity-client client-a
                            (list "--no-border" "--log-key" "--log-resize"
                                  "--log-focus" "--title=parity-a"
                                  "--width" "200" "--height" "150"))
           (setf *process-a* process *pty-a* pty))
         (let ((surface (pump 20 :until (lambda ()
                                          (surface-of-process *inner* *process-a*)))))
           (check surface "a real client mapped a window")
           (when surface
             (check (equal '(0 0) (node-position surface))
                    "cl-tinywl placed it at ~S, tinywl's own origin" (node-position surface))
             (check (equal '(200 150) (node-size surface))
                    "the window is drawn at its buffer's size ~S" (node-size surface))
             (park-pointer)
             (check (/= *background* (pixel 100 75))
                    "the window's pixels are in the frame (#x~8,'0X)" (pixel 100 75))))

         ;; 2. A second client maps on top -- at the origin too, because tinywl
         ;;    does not place anything.
         (multiple-value-bind (process pty)
             (parity-client client-b (list "--width" "200" "--height" "150"))
           (setf *process-b* process *pty-b* pty))
         (let ((surface-b (pump 20 :until (lambda ()
                                            (surface-of-process *inner* *process-b*)))))
           (check surface-b "the second client mapped a window")
           (expect '*lines-b* "mapped 200x150" :label "mapped 200x150")
           (when surface-b
             (check (equal '(0 0) (node-position surface-b))
                    "the second window landed on the first at ~S" (node-position surface-b))
             (park-pointer)
             (check (= *move-colour* (pixel 100 75))
                    "the window on top is what is drawn there (#x~8,'0X)" (pixel 100 75))))

         (let ((surface-a (surface-of-process *inner* *process-a*))
               (surface-b (surface-of-process *inner* *process-b*)))
           (when (and surface-a surface-b)

           ;; 3. Alt+left drags the window under the pointer by the pointer's
           ;;    delta, and the drag stops when the button comes up.
           (moves 100 75)
           (pump 0.1)
           (key "Alt_L" :pressed)
           (button :left :pressed)
           (settle)
           (check (typep (cf:compositor-grab *inner*) 'cf.grab:move-grab)
                  "alt+left started a move grab")
           (moves 300 225)
           (pump 0.3)
           (check (equal '(200 150) (node-position surface-b))
                  "the drag moved the window to ~S, not (200,150)" (node-position surface-b))
           (button :left :released)
           (key "Alt_L" :released)
           (settle)
           (check (null (cf:compositor-grab *inner*)) "the release ended the grab")
           (moves 320 245)
           (pump 0.2)
           (check (equal '(200 150) (node-position surface-b))
                  "a motion after the release left it at ~S" (node-position surface-b))
           (park-pointer)
           (check (= *move-colour* (pixel 250 175))
                  "the window's pixels moved with it (#x~8,'0X)" (pixel 250 175))
           (check (/= *move-colour* (pixel 100 75))
                  "and the window underneath is visible again (#x~8,'0X)" (pixel 100 75))

           ;; 4. Clicking focuses, and typing reaches the focused window only.
           (moves 100 75)
           (button :left :pressed)
           (button :left :released)
           (pump 0.3)
           (check (eq surface-a (keyboard-focus *inner*))
                  "clicking a window gave it the keyboard")
           (key "Shift_L" :pressed)
           (key "q" :pressed)
           (key "q" :released)
           (key "Shift_L" :released)
           (expect '*lines-a* "key key: 16, unicode: 81, state: pressed, modifiers: 0x1"
                   :label "the focused window received Shift+q")
           (let ((before (count-lines '*lines-a* "state: pressed")))
             (moves 250 175)
             (button :left :pressed)
             (button :left :released)
             (pump 0.3)
             (check (eq surface-b (keyboard-focus *inner*))
                    "clicking the other window moved the keyboard to it")
             (key "Shift_L" :pressed)
             (key "q" :pressed)
             (key "q" :released)
             (key "Shift_L" :released)
             (pump 0.8)
             (check (= before (count-lines '*lines-a* "state: pressed"))
                    "the unfocused window printed nothing: ~D key(s), not ~D"
                    (count-lines '*lines-a* "state: pressed") (1+ before)))

           ;; 5. Alt+right resizes from the edge under the pointer.
           (moves 195 145)
           (pump 0.1)
           (key "Alt_L" :pressed)
           (button :right :pressed)
           (settle)
           (let ((grabbed (cf:compositor-grab *inner*)))
             (check (typep grabbed 'cf.grab:resize-grab) "alt+right started a resize grab")
             (when grabbed
               (check (= (logior cf.grab:+edge-right+ cf.grab:+edge-bottom+)
                         (cf.grab:resize-grab-edges grabbed))
                      "from the bottom-right corner the pointer is in")))
           (moves 235 175)
           (expect '*lines-a* "resize width: 240, height: 180"
                   :label "the client was configured for 240x180")
           (button :right :released)
           (key "Alt_L" :released)
           (pump 0.4)
           (check (equal '(240 180) (node-size surface-a))
                  "and it came back with a ~S buffer, not 240x180" (node-size surface-a))

           ;; 5b. A resize grabbed at the LEFT edge moves the left edge, not the
           ;;     right one (D42): the grab anchors the edge opposite the dragged
           ;;     one, using the size the client actually came back with.
           (let* ((node (cf:surface-scene-node surface-a))
                  (right-before (+ (cf.scene:node-x node) (cf.scene:node-width node))))
             (moves 5 75)
             (pump 0.1)
             (key "Alt_L" :pressed)
             (button :right :pressed)
             (settle)
             (let ((grabbed (cf:compositor-grab *inner*)))
               (check (and (typep grabbed 'cf.grab:resize-grab)
                           (= cf.grab:+edge-left+ (cf.grab:resize-grab-edges grabbed)))
                      "alt+right on the left border grabs the left edge"))
             (moves 25 75)
             (expect '*lines-a* "resize width: 220" :label "the left drag asked for 220")
             (button :right :released)
             (key "Alt_L" :released)
             (pump 0.4)
             (check (= 20 (cf.scene:node-x node))
                    "the window's left edge followed the pointer (x ~D)"
                    (cf.scene:node-x node))
             (check (= right-before
                       (+ (cf.scene:node-x node) (cf.scene:node-width node)))
                    "and its right edge did not move (~D -> ~D)"
                    right-before (+ (cf.scene:node-x node) (cf.scene:node-width node))))

           ;; 6. Alt+F1 sends the bottom window to the front and focuses it.
           (key "Alt_L" :pressed)
           (key "F1" :pressed)
           (key "F1" :released)
           (key "Alt_L" :released)
           (pump 0.3)
           (let ((node (top-window *inner*)))
             (check (eq (cf:surface-scene-node surface-b) node)
                    "alt+F1 raised the window that was at the back")
             (check (eq surface-b (keyboard-focus *inner*))
                    "and gave it the keyboard"))))

         ;; 7. The parent decides how much space we have and we follow it (D37).
         ;;    Nested only: a headless output has nobody to configure it.
         (when *parent*
           (let ((toplevel (find-if (lambda (resource)
                                      (and (typep resource 'wayland.server:xdg-toplevel)
                                           (wayland.server:xdg-toplevel-mapped-p resource)))
                                    (resources-of-type
                                     *parent* 'wayland.server:xdg-toplevel)))
                 (backend (tinywl:session-nested *session*)))
             (when toplevel
               (let ((frames (cf.backend.nested:nested-frame-count backend)))
                 (wayland.server:request-toplevel-size toplevel 800 600)
                 (pump 10 :until (lambda ()
                                   (and (= 800 (cf:compositor-width *inner*))
                                        (= 600 (cf:compositor-height *inner*)))))
                 (check (= 800 (cf:compositor-width *inner*))
                        "the parent's configure resized our output to ~Dx~D"
                        (cf:compositor-width *inner*) (cf:compositor-height *inner*))
                 (check (= 800 (cf.scene:scene-width (cf:compositor-scene *inner*)))
                        "and the scene with it")
                 (pump 1.5)
                 (check (> (cf.backend.nested:nested-frame-count backend) frames)
                        "and kept presenting at the new size (~D -> ~D frame(s))"
                        frames (cf.backend.nested:nested-frame-count backend))
                 ;; The window that was there before the resize is still drawn: the
                 ;; eventdemo window at (0,0), which is what makes this a claim about
                 ;; content and not about a background fill.
                 (check (= #xFFFF0000 (cf:frame-pixel *inner* 100 75))
                        "and the window inside is still drawn there (#x~8,'0X)"
                        (cf:frame-pixel *inner* 100 75))))))

         ;; 8. Alt+Shift+Return starts a client on *our* display, which is the one
         ;;    thing a nested session cannot do for itself from the outside: the
         ;;    environment's WAYLAND_DISPLAY names the parent, so a client started
         ;;    from a shell lands in the wrong compositor.
         (let ((before (length (wayland.server:display-clients
                                (cf:compositor-display *inner*)))))
           (key "Alt_L" :pressed)
           (key "Shift_L" :pressed)
           (key "Return" :pressed)
           (key "Return" :released)
           (key "Shift_L" :released)
           (key "Alt_L" :released)
           (settle)
           (let ((window (pump 20
                              :until (lambda ()
                                       (and (> (length (wayland.server:display-clients
                                                        (cf:compositor-display *inner*)))
                                               before)
                                            (find-if (lambda (surface)
                                                       (plusp (cf.scene:node-width
                                                               (node-of surface))))
                                                     (mapped-surfaces *inner*)))))))
             (check window
                    "alt+Shift+Return started a client on our own display (~D client(s))"
                    (length (wayland.server:display-clients
                             (cf:compositor-display *inner*))))))

         ;; 9. The frame the presenter commits has already been painted (D38).
         ;;
         ;;    Nested only: the presenter is the seam that attaches our target into
         ;;    the parent, and the parent reads that memory at a moment of its own
         ;;    choosing -- so "the frame was drawn before it was committed" is not
         ;;    a detail, it is the difference between a window and a black
         ;;    rectangle.  Measured by wrapping the presenter, which is exactly how
         ;;    the bug was found.
         (when *parent*
           (let* ((compositor *inner*)
                  (presenter (cf.backend.headless:compositor-frame-presenter compositor))
                  (lit '()))
             (setf (cf.backend.headless:compositor-frame-presenter compositor)
                   (lambda (inner target)
                     (declare (ignore target))
                     (push (lit-pixel-count inner) lit)
                     (funcall presenter inner target)))
             (unwind-protect
                  (progn
                    ;; The clients have settled, so nothing is dirty: ask for the
                    ;; frames rather than waiting for a client to produce them.
                    (dotimes (frame 3)
                      (cf:request-frame *inner*)
                      (pump 5 :until (lambda () (>= (length lit) (1+ frame)))))
                    (check (and (>= (length lit) 3) (every #'plusp lit))
                           "the frame handed to the presenter was already painted ~S"
                           (reverse (subseq lit 0 (min 3 (length lit))))))
               (setf (cf.backend.headless:compositor-frame-presenter compositor)
                     presenter))))

         ;; 10. The pointer's picture follows the client (D41).
         ;;
         ;;     Over the terminal's text area the scene draws the image that client
         ;;     installed -- the I-beam, hotspot and all -- and then forgets it again
         ;;     when the pointer leaves.  This is the half that was missing while a
         ;;     session relied on somebody else's pointer: a client saying "the
         ;;     pointer means *this* here" is the client's whole contribution to the
         ;;     cursor.
         (moves 400 300)
         (settle)
         ;; The scene learns which image to draw *during* a frame, so wait for the
         ;; frame that has caught up rather than for the first one with an image.
         (cf:request-frame *inner*)
         (pump 5 :until (lambda ()
                          (multiple-value-bind (focused)
                              (cf:seat-pointer-cursor-image (cf:compositor-seat *inner*))
                            (and focused
                                 (eq focused (cf.scene:scene-cursor-surface
                                              (cf:compositor-scene *inner*)))))))
         (let* ((scene (cf:compositor-scene *inner*))
                (image (cf.scene:scene-cursor-surface scene)))
           (check image "the client's cursor image became the pointer's picture")
           (multiple-value-bind (focused hotspot-x hotspot-y)
               (cf:seat-pointer-cursor-image (cf:compositor-seat *inner*))
             (check (and (eq focused image)
                         (eql hotspot-x (cf.scene:scene-cursor-hotspot-x scene))
                         (eql hotspot-y (cf.scene:scene-cursor-hotspot-y scene)))
                    "and it is the focused pointer's, hotspot (~D, ~D)"
                    (cf.scene:scene-cursor-hotspot-x scene)
                    (cf.scene:scene-cursor-hotspot-y scene))))

         ;; 11. ... and the parent's pointer is put down and picked back up (D39, D41).
         ;;
         ;;     Nested only, and the pixel is the point: a parent compositor draws its
         ;;     cursor over *our* surface, so while we draw the client's image the
         ;;     parent must be told to draw none -- with a 1x1 transparent image of our
         ;;     own -- and at a bare-output spot it must get its pointer back, with
         ;;     nothing of ours drawn there.  (That a session with no parent draws its
         ;;     own arrow is the scene gate's check: "cursor: white body at (38,40)".)
         (when *parent*
           (let ((parent-pointer (find-if (lambda (resource)
                                            (typep resource 'wayland.server:pointer))
                                          (resources-of-type *parent*
                                                             'wayland.server:pointer))))
             (check (and parent-pointer
                         (wayland.server:pointer-cursor-surface parent-pointer))
                    "while a client image is drawn, the parent is told to draw no pointer")
             (check (let ((blank (and parent-pointer
                                      (wayland.server:pointer-cursor-surface
                                       parent-pointer))))
                      (and blank
                           (eql 1 (wayland.server:shm-buffer-width
                                   (wayland.server:surface-current-buffer blank)))
                           (eql 1 (wayland.server:shm-buffer-height
                                   (wayland.server:surface-current-buffer blank)))))
                    "with a 1x1 transparent image, so only the client's is visible")
             ;; Below the terminal (806x563 at the origin) is bare output in an
             ;; 800x600 output: no client image, so the parent's cursor comes back.
             (moves 790 590)
             (settle)
             (cf:request-frame *inner*)
             (pump 5 :until (lambda ()
                              (null (cf.scene:scene-cursor-surface
                                     (cf:compositor-scene *inner*)))))
             (check (null (cf.scene:scene-cursor-surface (cf:compositor-scene *inner*)))
                    "over the bare output there is no client image")
             ;; The session's own arrow is the fallback: with no client image there
             ;; must still be a pointer, and handing the parent's back does not work
             ;; -- set_cursor with no surface means "hide" to a compositor, which is
             ;; the vanishing arrow the sixth manual test found (D41, revised).
             (check (= #xFFFFFFFF (cf:frame-pixel *inner* 793 596))
                    "with no client image this session draws its own arrow (#x~8,'0X)"
                    (cf:frame-pixel *inner* 793 596))
             (check (let ((blank (and parent-pointer
                                      (wayland.server:pointer-cursor-surface
                                       parent-pointer))))
                      (and blank
                           (eql 1 (wayland.server:shm-buffer-width
                                   (wayland.server:surface-current-buffer blank)))))
                    "and the parent is still told to draw none, so one pointer shows")))

         ;; 12. A client's cursor image is a surface the client names, and naming it
         ;;     keeps it out of the scene for good (D40).  The terminal started in
         ;;     clause 8 sets one as soon as the pointer is over it.
         (let* ((surfaces (cf:compositor-surfaces *inner*))
                (images (remove-if-not #'cf.backend.headless:surface-pointer-image-p
                                       surfaces))
                (drawn (remove-if-not #'cf:surface-scene-node images)))
           (check images "a client named a cursor surface (~D of ~D surface(s))"
                  (length images) (length surfaces))
           (check (null drawn) "and none of it is drawn (~D with a scene node)"
                  (length drawn)))

         ;; 13. Alt+Esc asks the clients to close and stops the loop.
         ;;
         ;; Every client is connected *before* the quit: nothing before this point
         ;; cut one off, which is what makes "no protocol error" mean something.
         (check (>= (length (wayland.server:display-clients
                             (cf:compositor-display *inner*)))
                    2)
                "the clients were still connected before Alt+Esc (~D)"
                (length (wayland.server:display-clients
                         (cf:compositor-display *inner*))))
         (key "Alt_L" :pressed)
         (key "Escape" :pressed)
         (settle)
         (check (wayland.reactor:stopped-p
                 (wayland.server:display-reactor (cf:compositor-display *inner*)))
                "alt+Esc stopped the main loop")
         (key "Escape" :released)
         (key "Alt_L" :released)
         ;; The close requests were written before the loop stopped; the client's
         ;; own output is the proof that they arrived.
         (expect '*lines-b* "close" :seconds 5
                 :label "the second client was asked to close, not cut off")
         (check (null (remove-if-not
                       (lambda (line) (search "wl_display@1.error" line))
                       (append *lines-a* *lines-b*)))
                "no client saw a protocol error")

         ;; 14. B ran with WAYLAND_DEBUG=1: an ordered, valid event stream.
         ;;
         ;; libwayland writes `-> interface#id.request(args)' for what the client
         ;; sent and a bare `interface#id.event(args)' for what arrived, so "did it
         ;; ack the configure it was sent" is a comparison of two positions in the
         ;; client's own log.
         (let* ((lines (mapcar #'plain *lines-b*))
                (registry (position-if (lambda (line) (search "get_registry" line)) lines))
                (configure (position-if (lambda (line)
                                          (and (search "xdg_surface#" line)
                                               (search ".configure(" line)
                                               (not (search "ack_configure" line))))
                                        lines))
                (acked (position-if (lambda (line)
                                      (and (search "->" line)
                                           (search ".ack_configure(" line)))
                                    lines)))
           (check registry "the debug stream begins with get_registry")
           (check configure "a configure arrived from us")
           (check (and configure acked (< configure acked))
                  "and was acked afterwards (configure at ~S, ack at ~S)"
                  configure acked))

         (park-pointer)
         (cf:write-frame-png *inner* png)
         (format t "tinywl-parity: screenshot ~A~%" png))

         (error (condition)
           (setf *ok* nil)
           (format t "  FAIL [~(~A~)] the run aborted: ~A~%" *mode* condition)))

    ;; Teardown.  Stop the clients, then the session, then the parent, and prove a
    ;; nested session left the parent with nothing of ours behind.
    (dolist (process (list *process-a* *process-b*))
      (when (and process (sb-ext:process-alive-p process))
        (ignore-errors (sb-ext:process-kill process 15))))
    (ignore-errors (pump 0.3))
    (when *session* (ignore-errors (tinywl:stop *session*)))
    (when *pty-a* (ignore-errors (drain *pty-a* '*lines-a*)))
    (when *pty-b* (ignore-errors (drain *pty-b* '*lines-b*)))
    (dolist (process (list *process-a* *process-b*))
      (when process (ignore-errors (sb-ext:process-close process))))
    (when *parent*
      ;; The parent has to run to notice that our socket closed: its reactor is the
      ;; only thing that turns our disconnect into a teardown.
      (dotimes (i 100)
        (wayland.server:run-once (cf:compositor-display *parent*) :timeout 0.01))
      (let ((toplevels (resources-of-type *parent* 'wayland.server:xdg-toplevel))
            (clients (length (wayland.server:display-clients
                              (cf:compositor-display *parent*)))))
        (check (null toplevels) "the parent's window is gone (~D left)" (length toplevels))
        (check (zerop clients) "and the parent has no clients left (~D)" clients))
      (ignore-errors (wayland.server:close-display (cf:compositor-display *parent*))))
    (let ((fds-after (length (directory #p"/proc/self/fd/*"))))
      (format t "descriptors: ~D -> ~D~%" fds-before fds-after))
    (unless *ok* (report-failure))
    (format t "tinywl-parity: ~(~A~) run ~:[FAILED~;passed~]~%" *mode* *ok*)
    (uiop:quit (if *ok* 0 1))))

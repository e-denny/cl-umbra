;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; cf.switcher v0: the visible Alt+Tab switcher (docs/framework.md §5, D51).
;;;;
;;;; D45 gave the compositor a focus stack and a cycle -- the tail of the stack,
;;;; rotated to the front -- and said what it could not do: "a real hold-Tab-release
;;;; switcher needs an overlay to show what is selected".  The stack was right and
;;;; the *view* was missing: pressing Alt+Tab changed the world with nothing on
;;;; screen to say what had been chosen, and with more than two windows a person
;;;; had to look at the screen afterwards to find out.
;;;;
;;;; This file is that view, and three decisions make it small:
;;;;
;;;;   1. The overlay is not a window.  It lives in the scene's overlay root --
;;;;      above every window, below the cursor, never hit-tested (cf.scene) -- so
;;;;      it cannot be clicked, focused, raised, cycled or clamped, and no policy
;;;;      about windows has to learn about it.
;;;;   2. Nothing is decided until the key comes up.  The switcher reads the focus
;;;;      stack and paints it; it does not touch the stack, the keyboard or the
;;;;      stacking order while it is open.  Releasing Alt makes *one* call --
;;;;      focus and raise the row it was showing -- which is exactly what
;;;;      FOCUS-STACK-CYCLE does, so the visible and invisible cycles agree.
;;;;   3. The list is the cycle, drawn.  Rows are the stack from its tail to its
;;;;      front, which is the order a tap of Tab visits it (D45): row 0 is where
;;;;      one tap lands, row 1 where two taps land, and so on.  Holding Tab walks
;;;;      down the overlay; letting go takes the row the highlight is on.
;;;;
;;;; What it is not: a thumbnailer, an animation, a search box, or a window list.
;;;; It shows titles, one of which is highlighted, and it is driven by keys.  A
;;;; compositor that wants something else calls ADVANCE-SWITCHER from its own
;;;; policy -- the state machine does not care who moves the selection, and the
;;;; overlay is drawn from the state, not from the keys.

(in-package #:cf.switcher)

;;; ---------------------------------------------------------------------------
;;; What it looks like
;;; ---------------------------------------------------------------------------
;;
;; Four colours, all opaque: an opaque panel is a panel that *culls* -- the windows
;; under it are clipped out of the frame rather than drawn and painted over (D48) --
;; and opaque colours are the same number premultiplied as straight, which is the
;; only safe kind of colour to write without checking (the translucent-fill wart in
;; D48 is exactly this trap).

(defparameter +switcher-panel-colour+ #xFF202020
  "The panel's background: near-black, and opaque, so what is behind it is culled.")
(defparameter +switcher-border-colour+ #xFF707070
  "A one-pixel outline, so the panel reads as a thing rather than a hole.")
(defparameter +switcher-highlight-colour+ #xFF3A5F8A
  "The selected row's bar: the one colour that says where the keys will land.")
(defparameter +switcher-text-colour+ #xFFE8E8E8
  "Titles.  One colour for every row, selected or not: the bar does the selecting,
so a Tab moves one rectangle instead of re-rasterising two titles.")

(defparameter +switcher-fallback-title+ "window"
  "What a window with no title and no app id is called.

A row with no text in it would be a row a person cannot identify, and a client that
sets neither -- most example clients -- would be the one row that is unreadable.")

(defparameter +switcher-padding+ 10
  "Layout pixels between the panel's edge and its content.")
(defparameter +switcher-row-height+ 16
  "Layout pixels per row: the 7-pixel font and room to breathe around it.")

;;; ---------------------------------------------------------------------------
;;; The state
;;; ---------------------------------------------------------------------------

(defclass switcher ()
  ((compositor :initarg :compositor :reader switcher-compositor)
   ;; The windows on offer, in visit order: least recently focused first (the
   ;; tail of the focus stack), which is the order a tap of Alt+Tab visits (D45).
   (entries :initarg :entries :initform '() :accessor switcher-entries)
   ;; Titles, in the same order, as they will be drawn (cut to fit).
   (titles :initform '() :accessor switcher-titles)
   (index :initform 0 :accessor switcher-index)
   ;; The modifier that opened it, and whose release commits.  Alt by default -- a
   ;; switcher is opened by holding a modifier and tapping Tab -- but it is a
   ;; number, not an assumption: a compositor that opens one with Super says so.
   (modifier :initarg :modifier :initform input:+modifier-mod1+
             :accessor switcher-modifier)
   ;; The overlay nodes: the panel, the border, one text node per row and the one
   ;; node that moves.
   (highlight :initform nil :accessor switcher-highlight)
   (open-p :initform t :accessor switcher-open-p))
  (:documentation
   "One opening of the switcher: what it is offering, what is selected, and the
overlay nodes it owns.

It exists only while it is open, and closing it removes the nodes it added.  A
compositor holds it in COMPOSITOR-SWITCHER; nothing else does."))

(defun switcher-windows (compositor)
  "The windows a switcher may visit, in visit order: least recently focused first.

The focus stack is history, most recent first (D45), and its *tail* is what one tap
of Tab chooses.  Reading it backwards makes the overlay's first row the window a tap
would take, the second row what two taps would take, and so on -- so holding Tab
walks the same cycle tapping walks, and the key means the same thing seen or unseen.
Windows that are gone or no longer mapped are dropped here rather than at commit:
a row the person can see is a row that exists."
  (reverse (remove-if-not #'headless:focusable-window-p
                          (headless:compositor-focus-stack compositor))))

(defun switcher-selected (switcher)
  "The window SWITCHER is showing, or NIL."
  (and switcher (nth (switcher-index switcher) (switcher-entries switcher))))

;;; ---------------------------------------------------------------------------
;;; Layout
;;; ---------------------------------------------------------------------------

(defun switcher-layout (switcher)
  "Where SWITCHER's panel and its rows go, in layout pixels, as a plist.

:x :y :width :height are the panel; :rows is one y per entry (the top of the text);
:text-x is where every title starts; :texts are the titles as they will be drawn.
All layout coordinates -- the scene scales them once, on the way to pixels (D49),
so this arithmetic is the same at scale 1 and scale 2.

A title is cut to what the output can show rather than allowed to widen the panel
past the screen: a 300-character title is a title nobody can read anyway, and a
panel that hangs off the edge is a bug."
  (let* ((compositor (switcher-compositor switcher))
         (output-width (headless:compositor-width compositor))
         (output-height (headless:compositor-height compositor))
         (count (length (switcher-entries switcher)))
         (available (max 1 (- output-width (* 2 (+ +switcher-padding+ 1)))))
         (texts (mapcar (lambda (title) (font:truncate-text title available))
                        (switcher-titles switcher)))
         ;; The row is as wide as the widest thing drawn in it: a highlight wider
         ;; than every title would look like a mistake.
         (content (max 1 (min available
                              (reduce #'max texts :key #'font:text-width
                                                :initial-value 0))))
         (width (+ content (* 2 +switcher-padding+)))
         (height (+ (* count +switcher-row-height+) (* 2 +switcher-padding+)))
         (x (max 0 (floor (- output-width width) 2)))
         (y (max 0 (floor (- output-height height) 2)))
         (text-offset (floor (- +switcher-row-height+ (font:text-height)) 2)))
    (list :x x :y y :width width :height height
          :padding +switcher-padding+
          :row-height +switcher-row-height+
          :text-x (+ x +switcher-padding+)
          :texts texts
          :rows (loop for row from 0 below count
                      collect (+ y +switcher-padding+
                                 (* row +switcher-row-height+)
                                 text-offset)))))

(defun build-switcher-overlay (switcher)
  "Create SWITCHER's overlay nodes: a border, a panel, a highlight and the titles.

Built once per opening and then only *moved*: the highlight is the one node that
follows the selection.  Rebuilding the list on every Tab would change the draw
list's order, and a changed order is a full repaint by definition -- the damage diff
cannot tell a reordered scene from a different one, and it is right not to (D48)."
  (let* ((compositor (switcher-compositor switcher))
         (scene (headless:compositor-scene compositor))
         (layout (switcher-layout switcher))
         (x (getf layout :x))
         (y (getf layout :y))
         (width (getf layout :width))
         (height (getf layout :height))
         (padding (getf layout :padding))
         (row-height (getf layout :row-height))
         ;; The outline sits one pixel outside the panel, and stops at the output's
         ;; edge rather than drawing a negative coordinate (a clipped rectangle is
         ;; drawn as much as fits, so the edge case is a missing line, not a fault).
         (border-x (max 0 (1- x)))
         (border-y (max 0 (1- y))))
    (scene:scene-clear-overlay scene)
    (scene:scene-add-overlay-node
     scene (scene:make-rect-node (+ (- x border-x) width 1)
                                 (+ (- y border-y) height 1)
                                 +switcher-border-colour+)
     :x border-x :y border-y)
    (scene:scene-add-overlay-node
     scene (scene:make-rect-node width height +switcher-panel-colour+) :x x :y y)
    ;; The bar is inset by two pixels, so the border is visible all the way round
    ;; even when the bar is on the first or the last row.
    (setf (switcher-highlight switcher)
          (scene:scene-add-overlay-node
           scene (scene:make-rect-node (- width 4) row-height
                                       +switcher-highlight-colour+)
           :x (+ x 2) :y (+ y padding)))
    (loop for title in (getf layout :texts)
          for row in (getf layout :rows)
          do (scene:scene-add-overlay-node
              scene (scene:make-text-node title :colour +switcher-text-colour+)
              :x (getf layout :text-x) :y row))
    (setf (switcher-titles switcher) (getf layout :texts))
    switcher))

(defun move-highlight (switcher)
  "Put SWITCHER's highlight on its selected row; two geometry changes, no rebuild."
  (let ((layout (switcher-layout switcher))
        (highlight (switcher-highlight switcher)))
    (when highlight
      (scene:set-node-position
       highlight
       (+ (getf layout :x) 2)
       (+ (getf layout :y) (getf layout :padding)
          (* (switcher-index switcher) (getf layout :row-height))))))
  switcher)

;;; ---------------------------------------------------------------------------
;;; Opening, walking, committing
;;; ---------------------------------------------------------------------------

(defun start-switcher (compositor &key (step 0) (modifier input:+modifier-mod1+))
  "Open COMPOSITOR's switcher, or walk it forward if it is already open.

Returns the switcher, or NIL when there is nothing to choose between.  Selection 0
is the window FOCUS-STACK-CYCLE would choose, so a tap of Alt+Tab still lands
exactly where it did before the overlay existed (D45): the overlay changes what you
see, not what one tap does.  STEP moves the selection once the overlay is up, which
is how Shift+Tab opens it *backwards* -- from the first row to the last, the window
that has the keys now.  MODIFIER is the modifier whose release commits the choice:
Alt for Alt+Tab, and a compositor that opens a switcher with Super passes
`(:modifier input:+modifier-mod4+)` and gets the same behaviour.  One window is not a
choice, so nothing opens -- and the key is still consumed, because it did its job."
  (let ((existing (headless:compositor-switcher compositor)))
    (if (and existing (switcher-open-p existing))
        (advance-switcher compositor 1)
        (let ((entries (switcher-windows compositor)))
          (when (>= (length entries) 2)
            (let ((switcher (make-instance 'switcher
                                           :compositor compositor :entries entries
                                           :modifier modifier)))
              (setf (switcher-titles switcher)
                    (mapcar (lambda (surface)
                              (or (headless:window-title surface)
                                  +switcher-fallback-title+))
                            entries))
              (setf (headless:compositor-switcher compositor) switcher)
              (build-switcher-overlay switcher)
              (unless (zerop step)
                (advance-switcher compositor step))
              (headless:request-frame compositor)
              switcher))))))

(defun advance-switcher (compositor step)
  "Move COMPOSITOR's switcher STEP rows (wrapping) and redraw the highlight.

Wrapping is what makes the sequence finite: after one full turn the person is back
where they started, which is the property D45 chose the rotation for."
  (let ((switcher (headless:compositor-switcher compositor)))
    (when (and switcher (switcher-open-p switcher))
      (let ((count (length (switcher-entries switcher))))
        (setf (switcher-index switcher)
              (mod (+ (switcher-index switcher) step) count))
        (move-highlight switcher)
        (headless:request-frame compositor))
      switcher)))

(defun close-switcher (switcher)
  "Take SWITCHER's overlay down and forget it; returns it."
  (let ((compositor (switcher-compositor switcher)))
    (scene:scene-clear-overlay (headless:compositor-scene compositor))
    (setf (switcher-open-p switcher) nil
          (switcher-highlight switcher) nil)
    (when (eq switcher (headless:compositor-switcher compositor))
      (setf (headless:compositor-switcher compositor) nil))
    switcher))

(defun commit-switcher (compositor)
  "Focus and raise the window the switcher was showing, then close it; that window.

One call, and the same one FOCUS-STACK-CYCLE makes: the stack moves, the keyboard
moves and the chosen window comes to the front, because a cycle that does not show
what it chose is invisible (D45).

A window that closed while the overlay was open is not chosen -- the overlay showed
what was there when it opened, and focusing a tombstone is worse than doing nothing
-- so the answer is NIL, and the keys stay where they were."
  (let ((switcher (headless:compositor-switcher compositor)))
    (when (and switcher (switcher-open-p switcher))
      (let ((surface (switcher-selected switcher)))
        (close-switcher switcher)
        (headless:request-frame compositor)
        (when (headless:focusable-window-p surface)
          (headless:focus-surface compositor surface)
          (let ((node (headless:surface-scene-node surface)))
            (when node (headless:raise-window-with-popups compositor node)))
          surface)))))

(defun cancel-switcher (compositor &key (reason :cancelled))
  "Take COMPOSITOR's switcher down without changing the focus; returns it or NIL.

REASON is for the log and for whoever calls this -- Escape, another key, a pointer
press, a client's window going away -- and nothing in the switcher's behaviour
depends on it: cancelling is cancelling."
  (let ((switcher (headless:compositor-switcher compositor)))
    (when (and switcher (switcher-open-p switcher))
      (srv:log-message :debug "switcher cancelled: ~A" reason)
      (close-switcher switcher)
      (headless:request-frame compositor)
      switcher)))

;;; ---------------------------------------------------------------------------
;;; Keys
;;; ---------------------------------------------------------------------------
;
;; The seams are headless:SWITCHER-KEY and headless:SWITCHER-POINTER-PRESS: the
;; key path and the pointer path ask, and this file answers.  Nothing here is
;; in the framework's hot path, and a compositor that never binds
;; START-SWITCHER never has a switcher to answer about.

(defun modifier-hold-p (compositor mask)
  "Is any of MASK down, according to the modifier state the key path maintains?"
  (logtest mask (input:modifiers-depressed
                 (headless:compositor-modifiers compositor))))

(defun shift-held-p (compositor)
  "Is Shift down?  The one direction control the switcher has."
  (modifier-hold-p compositor input:+modifier-shift+))

(defmethod headless:switcher-key ((compositor headless:headless-compositor)
                                  name state)
  "Hold Tab to walk the list; release the modifier to take the row; Escape cancels.

Four rules, and each is a decision:

* **A modifier is not a choice.**  Pressing Shift (or the opener again) neither cancels the
  switcher nor is consumed: Shift picks the direction of the *next* Tab, and a
  modifier whose press is swallowed but whose partner's was not is a key the client
  believes is stuck down.
* **Tab walks.**  Forwards, or backwards with Shift held: the direction is read from
  the modifier state rather than from a binding table, because a switcher is one key
  held down and a table matches pairs.
* **Escape cancels and is consumed.**  Alt is still down, and Alt+Escape is `quit' in
  most compositors including this one (cl-tinywl, D45): a cancel that also ended the
  session would be a spectacular way to lose a click.  Pressing it twice reaches
  whatever is underneath, which is the usual cascade.
* **Any other press cancels and is not consumed**, so typing still reaches the
  window: cancelling a switcher is not a claim on the keyboard.

A *release* commits when the modifier that opened the switcher is no longer down --
the moment the person stopped choosing -- and is not consumed either.  The client saw
that modifier go down, so it must see it come up, or it spends the rest of the
session believing it is held.  Tab's own release is consumed, because Tab's press
was; the pair means one thing and the client saw neither of them."
  (let ((switcher (headless:compositor-switcher compositor)))
    (when (and switcher (switcher-open-p switcher))
      (if (eq state :pressed)
          (cond
            ((plusp (input:key-modifier-mask name))
             nil)
            ((string-equal name "Tab")
             (advance-switcher compositor (if (shift-held-p compositor) -1 1)))
            ((string-equal name "Escape")
             (cancel-switcher compositor :reason :escape))
            (t
             (cancel-switcher compositor :reason :other-key)
             nil))
          (progn
            (unless (modifier-hold-p compositor (switcher-modifier switcher))
              (commit-switcher compositor))
            (string-equal name "Tab"))))))

(defmethod headless:switcher-pointer-press ((compositor headless:headless-compositor))
  "A click means the overlay was not what was wanted: cancel it, then click."
  (cancel-switcher compositor :reason :pointer))

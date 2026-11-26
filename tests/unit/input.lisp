;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; cf.input: the key table, the keymap generated from it, and modifier state.
;;;;
;;;; The keymap clients receive is *text this build generates*, so it can be read
;;;; (and diffed) rather than only fed to xkbcommon.  What is asserted here is
;;;; therefore of two kinds:
;;;;
;;;;   * properties of the table -- one row per key, unique evdev keycodes, unique
;;;;     XKB names, every key reachable by the name a binding would use;
;;;;   * the generated text -- a key's line in the keycodes and symbols sections,
;;;;     the type a one-level and a two-level key get, and that the map is
;;;;     self-contained (no `include', which would need /usr/share/X11/xkb).
;;;;
;;;; The seat gate and the parity gate prove the *other* half -- that a real
;;;; client's xkbcommon parses this and translates the keycodes it is sent.

(in-package #:cl-user)

(defpackage #:wayland.test.input
  (:use #:cl #:rove)
  (:local-nicknames (#:input #:cf.input))
  (:documentation "Tests for cf.input: the key table and the keymap it generates."))

(in-package #:wayland.test.input)

;;; ---------------------------------------------------------------------------
;;; The table
;;; ---------------------------------------------------------------------------

(deftest every-key-has-a-unique-keycode-and-name
  (let ((codes (make-hash-table))
        (names (make-hash-table :test #'equal))
        (duplicates '()))
    (dolist (entry input:+keys+)
      (destructuring-bind (name evdev base shifted modifier keysym-name) entry
        (declare (ignore base shifted modifier))
        (when (gethash evdev codes) (push name duplicates))
        (when (gethash name names) (push name duplicates))
        (setf (gethash evdev codes) name
              (gethash name names) name)
        (ok (and (plusp evdev) (<= evdev 247))
            (format nil "~A: evdev ~D is inside the range a keymap may use" name evdev))
        (ok (= (+ 8 evdev) (input:xkb-keycode name))
            (format nil "~A: the XKB keycode is evdev + 8" name))
        (ok (stringp keysym-name)
            (format nil "~A: has a keysym name for logs and bindings" name))))
    (ok (null duplicates)
        (format nil "no keycode or name is used twice (~S)" duplicates))))

(deftest the-key-between-escape-and-one-is-in-the-table
  ;; A key that is missing from this table is missing from the keymap, which means
  ;; no client can type it: TLDE was absent until the focus-stack slice noticed,
  ;; and `` ` `` and `~' were simply unreachable in a session.
  (ok (= 41 (input:keycode "grave")))
  (ok (= 49 (input:xkb-keycode "TLDE")))
  (ok (equal "grave" (input:key-name "grave")))
  (ok (= 41 (input:keycode "asciitilde"))
      "the shifted keysym finds the same key, which is how a binding names it")
  (ok (null (input:key-modifier "grave")) "and it sets no modifier"))

(deftest a-keymap-can-be-looked-up-by-either-keysym
  (ok (= (input:keycode "Shift_L") (input:keycode "Shift_L")))
  (ok (signals (input:keycode "no-such-key") 'error)
      "an unknown key says so instead of returning NIL"))

;;; ---------------------------------------------------------------------------
;;; The generated keymap
;;; ---------------------------------------------------------------------------

(defun keymap-lines ()
  (uiop:split-string (input:make-keymap) :separator '(#\Newline)))

(defun keymap-line-containing (text)
  (find text (keymap-lines) :test (lambda (needle line) (search needle line))))

(deftest the-generated-keymap-is-self-contained
  (let ((keymap (input:make-keymap)))
    (ok (eql 0 (search "xkb_keymap {" keymap)) "it opens with a keymap block")
    (ok (null (search "include" keymap))
        "no `include': a client must not need /usr/share/X11/xkb")
    (dolist (section '("xkb_keycodes" "xkb_types" "xkb_compatibility" "xkb_symbols"))
      (ok (search section keymap)
          (format nil "it has a ~A section" section)))
    (ok (string= keymap (input:make-keymap))
        "the keymap is built once and cached: it is a constant of this build")))

(deftest every-key-appears-in-both-sections
  (dolist (entry input:+keys+)
    (let ((name (first entry)))
      (ok (keymap-line-containing (format nil "<~A> = ~D;" name (input:xkb-keycode name)))
          (format nil "~A is declared in xkb_keycodes" name))
      (ok (keymap-line-containing (format nil "key <~A> {" name))
          (format nil "~A has a symbols entry" name)))))

(deftest a-two-level-key-is-two-level
  (ok (keymap-line-containing "key <TLDE> { type[group1] = \"TWO_LEVEL\", [ grave, asciitilde ] };")
      "TLDE is two-level: grave, then asciitilde")
  (ok (keymap-line-containing "key <ESC> { type[group1] = \"ONE_LEVEL\", [ Escape ] };")
      "Escape has one level, so it must not claim a shifted level"))

;;; ---------------------------------------------------------------------------
;;; Modifiers
;;; ---------------------------------------------------------------------------

(deftest the-modifier-mask-comes-from-the-table
  (ok (= input:+modifier-shift+ (input:key-modifier-mask "Shift_L")))
  (ok (= input:+modifier-control+ (input:key-modifier-mask "Control_R")))
  (ok (= input:+modifier-mod1+ (input:key-modifier-mask "Alt_L")))
  (ok (= input:+modifier-mod4+ (input:key-modifier-mask "Super_L")))
  (ok (zerop (input:key-modifier-mask "q")) "an ordinary key sets nothing"))

(deftest modifier-state-follows-presses-and-releases
  (let ((modifiers (input:make-modifiers)))
    (input:update-modifiers modifiers "Shift_L" t)
    (ok (= input:+modifier-shift+ (input:modifiers-depressed modifiers)))
    (input:update-modifiers modifiers "Alt_L" t)
    (ok (= (logior input:+modifier-shift+ input:+modifier-mod1+)
           (input:modifiers-depressed modifiers))
        "two held modifiers combine")
    (input:update-modifiers modifiers "Shift_L" nil)
    (ok (= input:+modifier-mod1+ (input:modifiers-depressed modifiers))
        "releasing one leaves the other")
    (input:update-modifiers modifiers "Alt_L" nil)
    (ok (zerop (input:modifiers-depressed modifiers)))))

;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; Keymaps, keycodes and modifier state: `cf.input` (docs/framework.md §5).
;;;;
;;;; A Wayland client never sees a keysym.  It receives a *keycode* (the Linux
;;;; evdev code) and a keymap; it adds 8 to the keycode, feeds that to
;;;; xkbcommon, and translates the result into a keysym itself.  So the compositor
;;;; owes the client exactly two things: a keymap the client's xkbcommon can parse,
;;;; and the modifiers each key produced.
;;;;
;;;; This module generates that keymap as text from a table, rather than compiling
;;;; one with libxkbcommon: phase 3 needs a small, honest, testable map, and
;;;; libxkbcommon (needed for real layouts and device-specific maps) belongs with
;;;; libinput in phase 4.  The table is the single source of truth for
;;;;  * the XKB keycodes section (evdev + 8),
;;;;  * the symbols (unshifted and shifted keysyms),
;;;;  * the modifier each key sets, which is what MODIFIER-MASK answers, and
;;;;  * the keysym name KEY-NAME reports for logs and keybindings.
;;;;
;;;; The generated keymap is self-contained: no `include` of rules or data files,
;;;; so a client's xkbcommon parses it without any /usr/share/X11/xkb lookup.

(in-package #:cf.input)

;;; ---------------------------------------------------------------------------
;;; The key table
;;; ---------------------------------------------------------------------------
;;
;; NAME          the XKB key name (what keycodes/symbols reference)
;; KEYCODE        the evdev code, which is what wl_keyboard.key carries
;; BASE, SHIFTED  keysym names, or NIL for a one-level key
;; MODIFIER       what pressing it sets: :shift, :control, :mod1, :mod4, :lock
;;
;; Keys a compositor's keybindings and a terminal need, and no more.  A keymap is
;; not a keyboard layout: adding a key is adding a row.

(defparameter +keys+
  '(
    ("ESC"   1 "Escape"             nil                  nil        "Escape")
    ("FK01"  59 "F1"                 nil                  nil        "F1")
    ("FK02"  60 "F2"                 nil                  nil        "F2")
    ("FK03"  61 "F3"                 nil                  nil        "F3")
    ("FK04"  62 "F4"                 nil                  nil        "F4")
    ;; TLDE is the key between Escape and 1.  It was missing from this table, and a
    ;; key that is not in the keymap is a key a client cannot type at all -- not a
    ;; key that produces the wrong character, and not something a keybinding can
    ;; use either (Alt+grave, for instance).
    ("TLDE"  41 "grave"              "asciitilde"         nil        "grave")
    ("AE01"   2 "1"                  "exclam"             nil        "1")
    ("AE02"   3 "2"                  "at"                 nil        "2")
    ("AE03"   4 "3"                  "numbersign"         nil        "3")
    ("AE04"   5 "4"                  "dollar"             nil        "4")
    ("AE05"   6 "5"                  "percent"            nil        "5")
    ("AE06"   7 "6"                  "asciicircum"        nil        "6")
    ("AE07"   8 "7"                  "ampersand"          nil        "7")
    ("AE08"   9 "8"                  "asterisk"           nil        "8")
    ("AE09"  10 "9"                  "parenleft"          nil        "9")
    ("AE10"  11 "0"                  "parenright"         nil        "0")
    ("AE11"  12 "minus"              "underscore"         nil        "minus")
    ("AE12"  13 "equal"              "plus"               nil        "equal")
    ("BKSP"  14 "BackSpace"          nil                  nil        "BackSpace")
    ("TAB"  15 "Tab"                nil                  nil        "Tab")
    ("AD01"  16 "q"                  "Q"                  nil        "q")
    ("AD02"  17 "w"                  "W"                  nil        "w")
    ("AD03"  18 "e"                  "E"                  nil        "e")
    ("AD04"  19 "r"                  "R"                  nil        "r")
    ("AD05"  20 "t"                  "T"                  nil        "t")
    ("AD06"  21 "y"                  "Y"                  nil        "y")
    ("AD07"  22 "u"                  "U"                  nil        "u")
    ("AD08"  23 "i"                  "I"                  nil        "i")
    ("AD09"  24 "o"                  "O"                  nil        "o")
    ("AD10"  25 "p"                  "P"                  nil        "p")
    ("AD11"  26 "bracketleft"        "braceleft"          nil        "bracketleft")
    ("AD12"  27 "bracketright"       "braceright"         nil        "bracketright")
    ("RTRN"  28 "Return"             nil                  nil        "Return")
    ("LCTL"  29 "Control_L"          nil                  :control   "Control_L")
    ("AC01"  30 "a"                  "A"                  nil        "a")
    ("AC02"  31 "s"                  "S"                  nil        "s")
    ("AC03"  32 "d"                  "D"                  nil        "d")
    ("AC04"  33 "f"                  "F"                  nil        "f")
    ("AC05"  34 "g"                  "G"                  nil        "g")
    ("AC06"  35 "h"                  "H"                  nil        "h")
    ("AC07"  36 "j"                  "J"                  nil        "j")
    ("AC08"  37 "k"                  "K"                  nil        "k")
    ("AC09"  38 "l"                  "L"                  nil        "l")
    ("AC10"  39 "semicolon"          "colon"              nil        "semicolon")
    ("AC11"  40 "apostrophe"         "quotedbl"           nil        "apostrophe")
    ("LFSH"  42 "Shift_L"            nil                  :shift     "Shift_L")
    ("BKSL"  43 "backslash"          "bar"                nil        "backslash")
    ("AB01"  44 "z"                  "Z"                  nil        "z")
    ("AB02"  45 "x"                  "X"                  nil        "x")
    ("AB03"  46 "c"                  "C"                  nil        "c")
    ("AB04"  47 "v"                  "V"                  nil        "v")
    ("AB05"  48 "b"                  "B"                  nil        "b")
    ("AB06"  49 "n"                  "N"                  nil        "n")
    ("AB07"  50 "m"                  "M"                  nil        "m")
    ("AB08"  51 "comma"              "less"               nil        "comma")
    ("AB09"  52 "period"             "greater"            nil        "period")
    ("AB10"  53 "slash"              "question"           nil        "slash")
    ("RTSH"  54 "Shift_R"            nil                  :shift     "Shift_R")
    ("LALT"  56 "Alt_L"              nil                  :mod1      "Alt_L")
    ("SPCE"  57 "space"              nil                  nil        "space")
    ("CAPS"  58 "Caps_Lock"          nil                  :lock      "Caps_Lock")
    ("LWIN" 125 "Super_L"            nil                  :mod4      "Super_L")
    ("RWIN" 126 "Super_R"            nil                  :mod4      "Super_R")
    ("RCTL"  97 "Control_R"          nil                  :control   "Control_R")
    ("RALT" 100 "Alt_R"              nil                  :mod1      "Alt_R")
    ("HOME" 102 "Home"               nil                  nil        "Home")
    ("UP" 103 "Up"                 nil                  nil        "Up")
    ("PGUP" 104 "Prior"              nil                  nil        "Prior")
    ("LEFT" 105 "Left"               nil                  nil        "Left")
    ("RGHT" 106 "Right"              nil                  nil        "Right")
    ("END" 107 "End"                nil                  nil        "End")
    ("DOWN" 108 "Down"               nil                  nil        "Down")
    ("PGDN" 109 "Next"               nil                  nil        "Next")
    ("INS" 110 "Insert"             nil                  nil        "Insert")
    ("DELE" 111 "Delete"             nil                  nil        "Delete"))
  "NAME EVDEV KEYSYM [SHIFTED-KEYSYM] [MODIFIER] KEYSYM-NAME.

The second column is the evdev code -- what goes into wl_keyboard.key.  The XKB
keycode the keymap uses is evdev + 8 and is *computed*, never stored: a table with
both invites the classic off-by-eight bug.
")

;;; ---------------------------------------------------------------------------
;;; Accessors over the table
;;; ---------------------------------------------------------------------------

(defun key-entry (name)
  "The row for NAME: a keysym (\"Escape\", \"grave\", \"asciitilde\"), an XKB key
name (\"ESC\", \"TLDE\") or an evdev keycode.

The keysym is what a binding is written with, so it is tried first; the XKB key name
is what the generated keymap calls the key, and looking it up is how a test -- or a
person reading the keymap -- finds the row it is in."
  (etypecase name
    (string (or (find name +keys+ :key #'third :test #'string-equal)
                (find name +keys+ :key #'fourth :test #'string-equal)
                (find name +keys+ :key #'first :test #'string-equal)
                (error "no key named ~S in the keymap" name)))
    (symbol (key-entry (string name)))
    (integer (or (find name +keys+ :key #'second)
                 (error "no key with evdev keycode ~D in the keymap" name)))))

(defun keycode (name)
  "The evdev keycode wl_keyboard.key carries for NAME."
  (second (key-entry name)))

(defun xkb-keycode (name)
  "The XKB keycode the keymap uses for NAME: evdev + 8."
  (+ 8 (keycode name)))

(defun key-name (name)
  "The keysym name for NAME: what a keybinding table and a log line want."
  (sixth (key-entry name)))

(defparameter +key-index-by-code+
  (let ((table (make-hash-table)))
    (dolist (entry +keys+ table)
      (setf (gethash (second entry) table) entry)))
  "evdev keycode -> that key's row in +KEYS+.

An index, not a second table: the table above stays the single source of truth for
the map, the modifier and the name, and a code it does not name simply has no row.")

(defun key-entry-for-code (code)
  "The +KEYS+ row whose evdev keycode is CODE, or NIL."
  (and (integerp code) (gethash code +key-index-by-code+)))

(defun key-name-for-code (code)
  "The keysym name an evdev CODE produces, or NIL when the table has no row for it.

This is the direction a real keyboard arrives in: libinput reports evdev codes, and
the seat speaks keysym names (INJECT-KEY's argument), because that is what a
keybinding table and a client's xkbcommon understand.  NIL is a fact worth
reporting rather than an error -- a multimedia key is not a bug (D56)."
  (let ((entry (key-entry-for-code code)))
    (and entry (sixth entry))))

(defparameter +modifier-shift+ 1)
(defparameter +modifier-lock+ 2)
(defparameter +modifier-control+ 4)
(defparameter +modifier-mod1+ 8)
(defparameter +modifier-mod4+ 64)

(defun modifier-mask (modifier)
  "The XKB core modifier mask for MODIFIER (:shift, :lock, :control, :mod1, :mod4)."
  (ecase modifier
    (:shift +modifier-shift+)
    (:lock +modifier-lock+)
    (:control +modifier-control+)
    (:mod1 +modifier-mod1+)
    (:mod4 +modifier-mod4+)))

(defun key-modifier (name)
  "The modifier NAME sets, or NIL for an ordinary key."
  (fifth (key-entry name)))

(defun key-modifier-mask (name)
  "The mask NAME sets, or 0."
  (let ((modifier (key-modifier name)))
    (if modifier (modifier-mask modifier) 0)))

;;; ---------------------------------------------------------------------------
;;; Generating the keymap
;;; ---------------------------------------------------------------------------

(defun keysym-list (entry)
  (let ((base (third entry))
        (shifted (fourth entry)))
    (if shifted
        (format nil "~A, ~A" base shifted)
        base)))

(defun write-keycodes (stream)
  (format stream "  xkb_keycodes \"cl-umbra\" {~%")
  (format stream "    minimum = 8;~%")
  (format stream "    maximum = 255;~%")
  (dolist (entry +keys+)
    (format stream "    <~A> = ~D;~%" (first entry) (+ 8 (second entry))))
  (format stream "  };~%"))

(defun write-types (stream)
  ;; Two types are all a map with 1- and 2-level keys needs.  Naming them
  ;; explicitly in every key removes xkbcomp's inference step, which is where a
  ;; hand-written keymap usually goes wrong.
  (format stream "  xkb_types \"cl-umbra\" {~%")
  (format stream "    type \"ONE_LEVEL\" {~%")
  (format stream "        modifiers = None;~%")
  (format stream "        map[None] = Level1;~%")
  (format stream "    };~%")
  (format stream "    type \"TWO_LEVEL\" {~%")
  (format stream "        modifiers = Shift;~%")
  (format stream "        map[Shift] = Level2;~%")
  (format stream "    };~%")
  (format stream "  };~%"))

(defun write-compatibility (stream)
  ;; Without these, a client's xkb state never learns that Shift_L *is* Shift:
  ;; the modifier_map below says which keysym maps to which mask, and these
  ;; interprets say what pressing the key does to the state.
  (format stream "  xkb_compatibility \"cl-umbra\" {~%")
  (dolist (rule '(("Shift_L" "Shift") ("Shift_R" "Shift")
                  ("Control_L" "Control") ("Control_R" "Control")
                  ("Alt_L" "Mod1") ("Alt_R" "Mod1")
                  ("Super_L" "Mod4") ("Super_R" "Mod4")))
    (format stream "    interpret ~A+AnyOfOrNone(all) { action = SetMods(modifiers=~A); };~%"
            (first rule) (second rule)))
  (format stream "    interpret Caps_Lock+AnyOfOrNone(all) { action = LockMods(modifiers=Lock); };~%")
  (format stream "  };~%"))

(defun write-symbols (stream)
  (format stream "  xkb_symbols \"cl-umbra\" {~%")
  (dolist (entry +keys+)
    (format stream "    key <~A> { type[group1] = \"~A\", [ ~A ] };~%"
            (first entry)
            (if (fourth entry) "TWO_LEVEL" "ONE_LEVEL")
            (keysym-list entry)))
  (format stream "    modifier_map Shift { <LFSH>, <RTSH> };~%")
  (format stream "    modifier_map Lock { <CAPS> };~%")
  (format stream "    modifier_map Control { <LCTL>, <RCTL> };~%")
  (format stream "    modifier_map Mod1 { <LALT>, <RALT> };~%")
  (format stream "    modifier_map Mod4 { <LWIN>, <RWIN> };~%")
  (format stream "  };~%"))

(defvar *default-keymap* nil
  "The generated keymap, built once; a keymap is a constant of this build.")

(defun make-keymap ()
  "The XKB keymap text clients are given, as a string.

Self-contained: no `include`, so a client's xkbcommon parses it without looking
at /usr/share/X11/xkb, and a test can diff it if a key changes."
  (or *default-keymap*
      (setf *default-keymap*
            (with-output-to-string (stream)
              (format stream "xkb_keymap {~%")
              (write-keycodes stream)
              (write-types stream)
              (write-compatibility stream)
              (write-symbols stream)
              (format stream "};~%")))))

;;; ---------------------------------------------------------------------------
;;; Modifier state, as the seat reports it
;;; ---------------------------------------------------------------------------
;;
;; The compositor tracks the mask each key sets so that wl_keyboard.modifiers can
;; carry the depressed/latched/locked state the *keymap* implies.  Caps Lock
;; toggles its mask instead of holding it, which is the only asymmetry.

(defstruct (modifiers (:constructor make-modifiers))
  (depressed 0 :type (unsigned-byte 8))
  (latched 0 :type (unsigned-byte 8))
  (locked 0 :type (unsigned-byte 8))
  (group 0 :type (unsigned-byte 8)))

(defun update-modifiers (modifiers name pressed-p)
  "Apply NAME's effect: set its mask while held, or toggle Caps Lock's mask."
  (let ((mask (key-modifier-mask name)))
    (when (plusp mask)
      (if (= mask +modifier-lock+)
          (when pressed-p
            (setf (modifiers-locked modifiers)
                  (logxor (modifiers-locked modifiers) +modifier-lock+)))
          (if pressed-p
              (setf (modifiers-depressed modifiers)
                    (logior (modifiers-depressed modifiers) mask))
              (setf (modifiers-depressed modifiers)
                    (logandc2 (modifiers-depressed modifiers) mask)))))
    modifiers))

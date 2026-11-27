;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; cf.input on libxkbcommon: the keymap, the names and the modifier state (D57).
;;;;
;;;; These tests compile real keymaps -- the library and /usr/share/X11/xkb are
;;;; there, and a keymap that does not compile is the first failure worth having --
;;;; and then ask the questions a compositor asks: which keycode does a binding's
;;;; name mean, what is a code called, which bit is Alt, and what does pressing
;;;; Shift do to the state a client will be told about.
;;;;
;;;; Layout-dependent assertions compile their own keymap (`:layout \"us\"` and
;;;; `:layout \"de\"`) rather than trusting the environment: the default keymap is
;;;; whatever XKB_DEFAULT_LAYOUT says, which on somebody's machine is not `us`, and
;;;; a test that assumed it would fail in Germany for the wrong reason.
;;;;
;;;; What only a client can answer -- that the serialized text parses in *its*
;;;; xkbcommon -- is scripts/xkb-gate.lisp's business.

(in-package #:cl-user)

(defpackage #:wayland.test.input
  (:use #:cl #:rove)
  (:local-nicknames (#:input #:cf.input))
  (:documentation "Tests for cf.input: keymaps, key names and modifier state (D57)."))

(in-package #:wayland.test.input)

;;; ---------------------------------------------------------------------------
;;; Fixtures
;;; ---------------------------------------------------------------------------

(defmacro with-keymap ((variable &rest arguments) &body body)
  "Bind VARIABLE to a freshly compiled keymap and free it afterwards."
  `(let ((,variable (input:compile-keymap ,@arguments)))
     (unwind-protect (progn ,@body)
       (input:unref-keymap ,variable))))

(defun key-names (keymap codes)
  (mapcar (lambda (code) (input:key-name-for-code code keymap)) codes))

;;; ---------------------------------------------------------------------------
;;; The keymap itself
;;; ---------------------------------------------------------------------------

(deftest the-default-keymap-compiles-and-serializes
  (let ((keymap (input:default-keymap)))
    (ok (typep keymap 'input:keymap))
    (let ((text (input:make-keymap)))
      (ok (and (stringp text) (plusp (length text))))
      (ok (search "xkb_keymap {" text)
          "the serialized map is XKB text, which is what wl_keyboard.keymap carries")
      (ok (search "xkb_symbols" text)
          "the symbols section is what a client's xkbcommon reads for keysyms")
      (ok (string= text (input:make-keymap))
          "the text is computed once and kept")
      (ok (string= text (input:keymap-text keymap))
          "MAKE-KEYMAP is the seat-facing name for KEYMAP-TEXT"))))

(deftest the-serialized-map-has-the-keys-a-terminal-needs
  ;; The map is the layout's now, not a table in this file, so what is asserted is
  ;; that the keys every session depends on are still in it.  The serialized form
  ;; writes keysym *values* (0xff1b) rather than names, so the values are what are
  ;; searched for: Escape, Tab, Return, the modifiers, F1/F2, an arrow, a letter.
  (let ((text (input:make-keymap)))
    (dolist (name '("Escape" "Tab" "Return" "BackSpace" "Shift_L" "Control_L"
                    "Alt_L" "Super_L" "F1" "F2" "Left" "space" "a" "z"))
      (let ((hex (format nil "#x~(~X~)" (input:keysym name))))
        ;; The map writes keysyms as 0xNNNN; the value is what matters, not case.
        (ok (or (search hex text :test #'char-equal)
                (search (format nil "0x~(~X~)" (input:keysym name)) text :test #'char-equal))
            (format nil "the keymap carries ~A (0x~X)" name (input:keysym name)))))))

(deftest a-layout-that-does-not-exist-is-reported-and-the-default-still-works
  ;; Two different contracts.  Naming a layout yourself and getting it wrong is a
  ;; mistake worth signalling: the library has no fallback for `zz', and silently
  ;; compiling something else would hide a typo in a config.  The *session's* keymap
  ;; is different -- a typo in XKB_DEFAULT_LAYOUT must not stop a compositor from
  ;; starting -- so DEFAULT-KEYMAP falls back and says so on stderr.
  (ok (signals (input:compile-keymap :layout "zz" :variant "nonsense") 'input:keymap-error))
  (let ((keymap (input:default-keymap)))
    (ok (stringp (input:keymap-text keymap)))
    (ok (equal "Tab" (input:key-name-for-code 15 keymap)))))

(deftest the-keymap-can-be-asked-what-it-is
  (with-keymap (keymap :rules "evdev" :model "pc105" :layout "us" :variant nil :options nil)
    (ok (equal "evdev" (input:keymap-rules keymap)))
    (ok (equal "pc105" (input:keymap-model keymap)))
    (ok (equal "us" (input:keymap-layout keymap)))
    (ok (<= 8 (input:keymap-min-keycode keymap))
        "the range starts at evdev's first usable code or below it")
    (ok (>= (input:keymap-max-keycode keymap) 255)
        "and covers every code wl_keyboard.key can carry")))

(deftest the-layout-comes-from-the-keymap-and-not-from-this-module
  ;; The point of compiling from rules: keycode 21 types `y' in `us' and `z' in
  ;; `de'.  Nothing in this project knows that; the keymap does.
  (with-keymap (us :layout "us")
    (ok (equal '("a" "y") (key-names us '(30 21)))))
  (with-keymap (de :layout "de")
    (ok (equal '("a" "z") (key-names de '(30 21)))
        "the same code is a different key in a different layout")
    (ok (equal '("y") (key-names de '(44))))))

;;; ---------------------------------------------------------------------------
;;; Codes and names
;;; ---------------------------------------------------------------------------

(deftest a-binding-name-finds-its-keycode
  (ok (= 15 (input:keycode "Tab")))
  (ok (= 60 (input:keycode "F2")))
  (ok (= 42 (input:keycode "Shift_L")))
  (ok (= 56 (input:keycode "Alt_L")))
  (ok (= 1 (input:keycode "Escape")))
  (ok (= 30 (input:keycode "a")))
  (ok (= 41 (input:keycode "asciitilde"))
      "a shifted keysym finds the key that types it")
  (ok (string-equal "f2" "F2")
      "names are matched case-insensitively, like a config file would")
  (ok (= 60 (input:keycode "f2"))))

(deftest a-name-the-layout-does-not-produce-is-an-error-with-the-name-in-it
  (ok (signals (input:keycode "no-such-keysym") 'error))
  (handler-case (input:keycode "no-such-keysym")
    (error (condition)
      (ok (search "no-such-keysym" (princ-to-string condition))
          "the report names what was asked for"))))

(deftest xkb-keycodes-are-evdev-plus-eight
  (ok (= 23 (input:xkb-keycode "Tab")))
  (ok (= (+ 8 (input:keycode "F2")) (input:xkb-keycode "F2"))))

(deftest a-code-is-named-by-the-keymaps-unshifted-level
  (ok (equal "a" (input:key-name-for-code 30)))
  (ok (equal "Shift_L" (input:key-name-for-code 42)))
  (ok (equal "Control_L" (input:key-name-for-code 29)))
  (ok (equal "Alt_L" (input:key-name-for-code 56)))
  (ok (equal "F1" (input:key-name-for-code 59)))
  (ok (equal "F2" (input:key-name-for-code 60)))
  (ok (equal "Escape" (input:key-name-for-code 1)))
  (ok (equal "Tab" (input:key-name-for-code 15)))
  (ok (equal "grave" (input:key-name-for-code 41))
      "the unshifted keysym is the key's name; asciitilde is the shifted level of it")
  (ok (null (input:key-name-for-code 240))
      "a code this keymap has nothing for is NIL, not an error")
  (ok (null (input:key-name-for-code nil)))
  (ok (null (input:key-name-for-code 0))))

(deftest keysyms-and-their-names-round-trip
  (dolist (name '("Tab" "F2" "Shift_L" "Escape" "a" "space" "Left"))
    (ok (equal name (input:keysym-name (input:keysym name)))
        (format nil "~A round-trips through the library" name))))

(deftest repeat-is-a-property-of-the-key
  (ok (input:key-repeats-p 30) "a letter repeats")
  (ok (input:key-repeats-p 60) "a function key repeats")
  (ok (not (input:key-repeats-p 29)) "Control_L does not"))

;;; ---------------------------------------------------------------------------
;;; Modifiers
;;; ---------------------------------------------------------------------------

(deftest the-mask-of-a-modifier-is-the-keymaps-answer
  (ok (= input:+modifier-shift+ (input:modifier-mask :shift)))
  (ok (= input:+modifier-control+ (input:modifier-mask :control)))
  (ok (= input:+modifier-mod1+ (input:modifier-mask :mod1)))
  (ok (= input:+modifier-mod4+ (input:modifier-mask :mod4)))
  (ok (signals (input:modifier-mask :mod9) 'error)
      "an unknown modifier is a mistake in a binding, not a silent zero"))

(deftest what-a-key-sets-is-asked-of-the-keymap
  ;; Press it in a throwaway state and read what became active: that survives a
  ;; layout that puts Compose where another puts AltGr.
  (ok (= input:+modifier-shift+ (input:key-modifier-mask "Shift_L")))
  (ok (= input:+modifier-shift+ (input:key-modifier-mask "Shift_R")))
  (ok (= input:+modifier-control+ (input:key-modifier-mask "Control_R")))
  (ok (= input:+modifier-mod1+ (input:key-modifier-mask "Alt_L")))
  (ok (= input:+modifier-mod4+ (input:key-modifier-mask "Super_L")))
  (ok (= input:+modifier-lock+ (input:key-modifier-mask "Caps_Lock")))
  (ok (zerop (input:key-modifier-mask "q"))
      "an ordinary key sets nothing")
  (ok (zerop (input:key-modifier-mask "no-such-keysym"))
      "a name the keymap does not have sets nothing rather than signalling"))

(deftest the-state-tracks-what-is-held
  (let ((modifiers (input:make-modifiers)))
    (unwind-protect
         (progn
           (ok (= 0 (input:modifiers-depressed modifiers)))
           (input:update-modifiers modifiers "Shift_L" t)
           (ok (= input:+modifier-shift+ (input:modifiers-depressed modifiers)))
           (input:update-modifiers modifiers "Control_L" t)
           (ok (= (logior input:+modifier-shift+ input:+modifier-control+)
                  (input:modifiers-depressed modifiers)))
           (input:update-modifiers modifiers "Shift_L" nil)
           (ok (= input:+modifier-control+ (input:modifiers-depressed modifiers))
               "releasing one key leaves the other held")
           (input:update-modifiers modifiers "Control_L" nil)
           (ok (= 0 (input:modifiers-depressed modifiers)))
           (ok (= 0 (input:modifiers-latched modifiers)))
           (ok (= 0 (input:modifiers-locked modifiers)))
           (ok (= 0 (input:modifiers-group modifiers))
               "one layout, so group 0"))
      (input:unref-modifiers modifiers))))

(deftest caps-lock-taps-toggle-the-lock
  ;; What is asserted is the user-visible contract -- one tap locks, the next
  ;; unlocks -- and not the masks in between, which are the library's business.
  ;; Measured against the same keymap in C: a tap's *press* applies the lock, and
  ;; the unlock lands on the second tap's *release*, so a test written against the
  ;; intermediate masks would be encoding an implementation detail of xkbcommon's
  ;; compatibility rules rather than the behaviour a person expects.  (The old
  ;; hand-written table, by contrast, had to pick a moment and picked the press.)
  (let ((modifiers (input:make-modifiers)))
    (unwind-protect
         (progn
           (input:update-modifiers modifiers "Caps_Lock" t)
           (input:update-modifiers modifiers "Caps_Lock" nil)
           (ok (= input:+modifier-lock+ (input:modifiers-locked modifiers))
               "one tap locks Caps Lock")
           (ok (= 0 (input:modifiers-depressed modifiers))
               "and the key is not still held")
           (input:update-modifiers modifiers "Caps_Lock" t)
           (input:update-modifiers modifiers "Caps_Lock" nil)
           (ok (= 0 (input:modifiers-locked modifiers))
               "the next tap unlocks it"))
      (input:unref-modifiers modifiers))))

(deftest the-state-says-what-a-key-types-now
  ;; KEY-NAME-FOR-CODE names the *key*; this names what it produces in the current
  ;; state, which is what a client applies its own keymap to.
  (let ((modifiers (input:make-modifiers)))
    (unwind-protect
         (progn
           (ok (equal "a" (input:modifiers-keysym-name modifiers 30)))
           (input:update-modifiers modifiers "Shift_L" t)
           (ok (equal "A" (input:modifiers-keysym-name modifiers 30))
               "held Shift, the same code types A"))
      (input:unref-modifiers modifiers))))

(deftest every-keymap-this-machine-can-compile-agrees-on-the-bindings-masks
  ;; The load-time check covers the default keymap.  A binding table written with
  ;; +MODIFIER-MOD1+ has to mean Alt in *any* keymap the user's environment can ask
  ;; for, so the invariant is asserted for an explicitly compiled one too.
  (with-keymap (keymap :rules "evdev" :model "pc105" :layout "us")
    (ok (= input:+modifier-shift+ (input:keymap-modifier-mask keymap :shift)))
    (ok (= input:+modifier-control+ (input:keymap-modifier-mask keymap :control)))
    (ok (= input:+modifier-mod1+ (input:keymap-modifier-mask keymap :mod1)))
    (ok (= input:+modifier-mod4+ (input:keymap-modifier-mask keymap :mod4)))))

;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The keymap gate (clause 24): the layout comes from the session, the keymap we
;;;; hand a client is the keymap we compiled, and the modifier state is the
;;;; library's (D57).
;;;;
;;;; Run by scripts/xkb-gate.sh, twice: once with XKB_DEFAULT_LAYOUT=us and once
;;;; with =de, and the shell checks that the *same* keycode types a different letter
;;;; in the two runs.  That is the claim phase 4d makes -- a keyboard layout is the
;;;; session's preference and not this build's -- and it cannot be tested inside one
;;;; image, because the library reads the environment when the keymap is compiled.
;;;;
;;;; What else is checked here:
;;;;
;;;;   * the serialized text parses back into a keymap that answers the same
;;;;     questions -- the only honest way to check that what a client receives is
;;;;     the keymap we think we compiled;
;;;;   * the keycode range covers every code wl_keyboard.key can carry;
;;;;   * a name a binding is written with (`Alt_L', `F2', `Tab') finds its keycode,
;;;;     and a shifted keysym (`asciitilde') finds the key that types it;
;;;;   * the modifier masks are the ones the binding constants claim -- asserted
;;;;     here as well as at load time, because a binding table is silent when it is
;;;;     wrong;
;;;;   * the state: Shift+a types `A', a Caps Lock tap locks and the next unlocks,
;;;;     a letter repeats and Control_L does not.
;;;;
;;;; No device and no client is needed.  Clause 12 is where a real client parses
;;;; the keymap fd we send; this clause is about the map itself.

(asdf:load-system "cl-compositor-framework")

(in-package #:cl-user)

(defvar *checks* 0)
(defvar *failures* 0)

(defun check (value description &rest arguments)
  (incf *checks*)
  (if value
      (format t "  ok   ~A~%" (apply #'format nil description arguments))
      (progn
        (incf *failures*)
        (format t "  FAIL ~A~%" (apply #'format nil description arguments))))
  value)

(defun signals-error-p (thunk)
  "True when THUNK signals, which is what a bad key name must do."
  (handler-case (progn (funcall thunk) nil)
    (error () t)))

(defun note (description &rest arguments)
  (format t "       ~A~%" (apply #'format nil description arguments)))

(defun finish (summary &rest arguments)
  (if (plusp *failures*)
      (progn
        (format t "~&xkb-gate: ~D check(s), ~D failed~%" *checks* *failures*)
        (sb-ext:exit :code 1))
      (progn
        (format t "~&xkb-gate: ~A~%" (apply #'format nil summary arguments))
        (sb-ext:exit :code 0))))

;;; ---------------------------------------------------------------------------
;;; The session's keymap
;;; ---------------------------------------------------------------------------

(let* ((keymap (cf.input:default-keymap))
       (text (cf.input:keymap-text keymap))
       (expected (uiop:getenv "CL_XKB_EXPECT")))
  (check (plusp (length text))
         "the session's keymap compiled: ~D bytes of XKB text" (length text))
  (check (search "xkb_keymap {" text)
         "and serializes as XKB text, which is what wl_keyboard.keymap carries")
  (check (search "xkb_symbols" text)
         "with a symbols section a client's xkbcommon can read keysyms from")
  (check (<= (cf.input:keymap-min-keycode keymap) 9)
         "keycodes start at evdev's first usable one, Escape = 9 (~D)"
         (cf.input:keymap-min-keycode keymap))
  (check (>= (cf.input:keymap-max-keycode keymap) 255)
         "and cover every code wl_keyboard.key can carry (up to ~D)"
         (cf.input:keymap-max-keycode keymap))
  (check (string= text (cf.input:make-keymap))
         "MAKE-KEYMAP -- what the seat sends -- is that text")

  ;; The environment claim.  XKB_DEFAULT_LAYOUT is what this process was started
  ;; with, so the shell runs this file twice and compares.
  (when expected
    (check (equal expected (cf.input:key-name-for-code 21))
           "XKB_DEFAULT_LAYOUT selected the layout: code 21 types ~S"
           (cf.input:key-name-for-code 21)))

  ;; The round trip: parse the text the client will parse, and ask it the same
  ;; questions.  A keymap that serializes to something the library cannot read back
  ;; is a keymap no client will accept.
  (let ((back (cf.input:keymap-from-string text)))
    (unwind-protect
         (progn
           (check (= (cf.input:keymap-max-keycode keymap)
                     (cf.input:keymap-max-keycode back))
                  "the serialized map parses back to the same keycode range")
           (check (equal (cf.input:key-name-for-code 15 keymap)
                         (cf.input:key-name-for-code 15 back))
                  "and names Tab the same way (~A)"
                  (cf.input:key-name-for-code 15 back))
           (dolist (code '(1 15 28 30 41 42 56 59 60 103 108))
             (check (equal (cf.input:key-name-for-code code keymap)
                           (cf.input:key-name-for-code code back))
                    "code ~D is called ~S in both"
                    code (cf.input:key-name-for-code code back)))
           (let ((modifiers (cf.input:make-modifiers back)))
             (unwind-protect
                  (progn
                    (cf.input:update-modifiers modifiers "Shift_L" t)
                    (check (equal "A" (cf.input:modifiers-keysym-name modifiers 30))
                           "a state built from the parsed map still types A with Shift held"))
               (cf.input:unref-modifiers modifiers))))
      (cf.input:unref-keymap back))))

;;; ---------------------------------------------------------------------------
;;; Names, codes and masks
;;; ---------------------------------------------------------------------------

(let ((keymap (cf.input:compile-keymap :rules "evdev" :model "pc105" :layout "us"))
      (german (cf.input:compile-keymap :rules "evdev" :model "pc105" :layout "de")))
  (unwind-protect
       (progn
         (format t "~&a second layout~%")
         (check (equal "y" (cf.input:key-name-for-code 21 keymap))
                "in us, code 21 types y")
         (check (equal "z" (cf.input:key-name-for-code 21 german))
                "in de, the same code types z")
         (check (equal "y" (cf.input:key-name-for-code 44 german))
                "and de's y is where us has z (code 44)")
         (check (string/= (cf.input:keymap-text keymap) (cf.input:keymap-text german))
                "the two layouts serialize differently, so a client sees the difference")
         ;; The named keymap, not the default one: this process may have been
         ;; started with a different layout (the shell runs this twice), and a
         ;; shifted keysym such as asciitilde moves between layouts.
         (check (= 15 (cf.input:keycode "Tab" keymap)) "a binding name finds its keycode (Tab = 15)")
         (check (= 60 (cf.input:keycode "F2" keymap)) "F2 = 60")
         (check (= 60 (cf.input:keycode "f2" keymap)) "and names are case-insensitive")
         (check (= 41 (cf.input:keycode "asciitilde" keymap))
                "a shifted keysym finds the key that types it (asciitilde = 41)")
         (check (= 21 (cf.input:keycode "z" german))
                "a keysym lookup can be asked of a keymap other than the session's")
         (check (signals-error-p (lambda () (cf.input:keycode "no-such-keysym" keymap)))
                "a name the layout does not produce is an error")
         (check (= cf.input:+modifier-shift+ (cf.input:keymap-modifier-mask keymap :shift))
                "Shift is mask #x~X" (cf.input:keymap-modifier-mask keymap :shift))
         (check (= cf.input:+modifier-mod1+ (cf.input:keymap-modifier-mask keymap :mod1))
                "Mod1 (Alt) is mask #x~X" (cf.input:keymap-modifier-mask keymap :mod1))
         (check (= cf.input:+modifier-mod4+ (cf.input:keymap-modifier-mask keymap :mod4))
                "Mod4 (Super) is mask #x~X" (cf.input:keymap-modifier-mask keymap :mod4))
         (check (= cf.input:+modifier-mod1+ (cf.input:key-modifier-mask "Alt_L" keymap))
                "pressing Alt_L sets exactly Mod1")
         (check (zerop (cf.input:key-modifier-mask "q" keymap))
                "pressing q sets nothing")
         (check (cf.input:key-repeats-p 30 keymap) "a letter repeats while held")
         (check (not (cf.input:key-repeats-p 29 keymap)) "Control_L does not"))
    (cf.input:unref-keymap keymap)
    (cf.input:unref-keymap german)))

;;; ---------------------------------------------------------------------------
;;; State
;;; ---------------------------------------------------------------------------

(let ((modifiers (cf.input:make-modifiers)))
  (unwind-protect
       (progn
         (format t "~&the state~%")
         (check (equal "a" (cf.input:modifiers-keysym-name modifiers 30)) "unshifted, code 30 types a")
         (cf.input:update-modifiers modifiers "Shift_L" t)
         (check (equal "A" (cf.input:modifiers-keysym-name modifiers 30)) "with Shift, it types A")
         (check (= cf.input:+modifier-shift+ (cf.input:modifiers-depressed modifiers))
                "and Shift is depressed (#x~X)" (cf.input:modifiers-depressed modifiers))
         (cf.input:update-modifiers modifiers "Shift_L" nil)
         (check (zerop (cf.input:modifiers-depressed modifiers)) "released, nothing is depressed")
         (check (zerop (cf.input:modifiers-group modifiers)) "one layout, so group 0")
         ;; A tap of Caps Lock locks; the next unlocks.  The masks in between are
         ;; the library's compatibility rules, not this project's business.
         (cf.input:update-modifiers modifiers "Caps_Lock" t)
         (cf.input:update-modifiers modifiers "Caps_Lock" nil)
         (check (= cf.input:+modifier-lock+ (cf.input:modifiers-locked modifiers))
                "one Caps Lock tap locks (#x~X)" (cf.input:modifiers-locked modifiers))
         (cf.input:update-modifiers modifiers "Caps_Lock" t)
         (cf.input:update-modifiers modifiers "Caps_Lock" nil)
         (check (zerop (cf.input:modifiers-locked modifiers)) "the next tap unlocks"))
    (cf.input:unref-modifiers modifiers)))

(finish "the keymap, its names, its masks and the state (~D checks)" *checks*)

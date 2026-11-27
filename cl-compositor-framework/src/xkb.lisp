;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; Keymaps, keycodes and modifier state: `cf.input` (docs/framework.md §5, D57).
;;;;
;;;; A Wayland client never sees a keysym.  It receives a *keycode* (the Linux
;;;; evdev code) and a keymap; it adds 8 to the keycode, feeds that to xkbcommon,
;;;; and translates the result into a keysym itself.  So the compositor owes the
;;;; client exactly two things: a keymap the client's xkbcommon can parse, and the
;;;; modifiers each key produced.
;;;;
;;;; Phase 3 owed them from a table of forty-odd keys, written out and serialized
;;;; by hand: a small, honest, self-contained map with one or two levels per key.
;;;; It could not be a keyboard layout, because a layout is what libxkbcommon and
;;;; /usr/share/X11/xkb are for.  Phase 4d links the library, and this module
;;;; becomes what wlroots' keyboard code is: compile the keymap from the *rules*
;;;; (evdev model, the layout the user configured, the variant, the options),
;;;; serialize it for clients, and let the library answer every question about it.
;;;;
;;;; Three consequences worth stating, because each one replaced something this
;;;; module used to do itself:
;;;;
;;;;   1. The keymap is no longer ours to read.  `xkb_keymap_new_from_names` merges
;;;;      the layout's includes and `xkb_keymap_get_as_string` writes the merged
;;;;      result, so a client parses a real layout -- four levels per key, dead
;;;;      keys, the works -- without looking at /usr/share/X11/xkb itself.
;;;;   2. The name of a key comes from the keymap.  The old table had a column for
;;;;      it; now `key-name-for-code` asks the keymap for the code's level-0
;;;;      keysym and `xkb_keysym_get_name` names it.  A binding still says "Tab";
;;;;      where that name now comes from is the layout, not this file.
;;;;   3. The modifier mask is the keymap's.  Shift is bit 0 in the standard rules
;;;;      and Alt is Mod1, but that is a property of the keymap, not a constant of
;;;;      the wire: `modifier-mask` reads the mask out of the compiled keymap, and
;;;;      the +MODIFIER-*+ constants are checked against it when it is compiled.
;;;;
;;;; What is still ours: the evdev code is what wl_keyboard.key carries (XKB
;;;; keycodes are evdev + 8, computed and never stored), the reverse lookup from a
;;;; name to a code (a binding table is written in names), and the *state* the seat
;;;; reports -- which is an xkb_state, updated per key, serialized per event.

(in-package #:cl-user)

(in-package #:cf.input)

;;; ---------------------------------------------------------------------------
;;; The library
;;; ---------------------------------------------------------------------------
;;
;; libxkbcommon is a leaf dependency of the input path (D4: CFFI for kernel and
;; driver APIs), loaded here and nowhere else.  Its objects are opaque and
;; reference counted: a context, a keymap, a state, each unref'd where it was
;; made.  Nothing is transcribed from a header, so there is no struct to check at
;; load time; what replaces that check is the assertion below that the compiled
;; keymap's modifier masks are the ones the constants claim.

(cffi:define-foreign-library libxkbcommon
  (:unix (:or "libxkbcommon.so.0" "libxkbcommon.so")))

(cffi:use-foreign-library libxkbcommon)

(cffi:defcstruct xkb-rule-names
  (rules :pointer)
  (model :pointer)
  (layout :pointer)
  (variant :pointer)
  (options :pointer))

(cffi:defcfun ("xkb_context_new" %context-new) :pointer
  (flags :int))

(cffi:defcfun ("xkb_context_unref" %context-unref) :void
  (context :pointer))

(cffi:defcfun ("xkb_keymap_new_from_names" %keymap-new-from-names) :pointer
  (context :pointer) (names :pointer) (flags :int))

(cffi:defcfun ("xkb_keymap_new_from_string" %keymap-new-from-string) :pointer
  (context :pointer) (string :string) (format :int) (flags :int))

(cffi:defcfun ("xkb_keymap_unref" %keymap-unref) :void
  (keymap :pointer))

(cffi:defcfun ("xkb_keymap_get_as_string" %keymap-get-as-string) :pointer
  (keymap :pointer) (format :int))

(cffi:defcfun ("xkb_keymap_min_keycode" %keymap-min-keycode) :uint32
  (keymap :pointer))

(cffi:defcfun ("xkb_keymap_max_keycode" %keymap-max-keycode) :uint32
  (keymap :pointer))

(cffi:defcfun ("xkb_keymap_key_get_syms_by_level" %key-syms-by-level) :int
  (keymap :pointer) (key :uint32) (layout :uint32) (level :uint32)
  (syms-out :pointer))

(cffi:defcfun ("xkb_keymap_mod_get_mask" %mod-get-mask) :uint32
  (keymap :pointer) (name :string))

(cffi:defcfun ("xkb_keymap_mod_get_index" %mod-get-index) :uint32
  (keymap :pointer) (name :string))

(cffi:defcfun ("xkb_keymap_key_repeats" %key-repeats) :int
  (keymap :pointer) (key :uint32))

(cffi:defcfun ("xkb_keysym_get_name" %keysym-get-name) :int
  (keysym :uint32) (buffer :pointer) (size :size))

(cffi:defcfun ("xkb_keysym_from_name" %keysym-from-name) :uint32
  (name :string) (flags :int))

(cffi:defcfun ("xkb_state_new" %state-new) :pointer
  (keymap :pointer))

(cffi:defcfun ("xkb_state_unref" %state-unref) :void
  (state :pointer))

(cffi:defcfun ("xkb_state_update_key" %state-update-key) :int
  (state :pointer) (key :uint32) (direction :int))

(cffi:defcfun ("xkb_state_key_get_syms" %state-key-get-syms) :int
  (state :pointer) (key :uint32) (syms-out :pointer))

(cffi:defcfun ("xkb_state_key_get_one_sym" %state-key-get-one-sym) :uint32
  (state :pointer) (key :uint32))

(cffi:defcfun ("xkb_state_serialize_mods" %state-serialize-mods) :uint32
  (state :pointer) (components :int))

(cffi:defcfun ("xkb_state_serialize_layout" %state-serialize-layout) :uint32
  (state :pointer) (components :int))

(defconstant +format-text-v1+ 1)
(defconstant +no-symbol+ 0)
(defconstant +key-up+ 0)
(defconstant +key-down+ 1)
(defconstant +state-mods-depressed+ 1)
(defconstant +state-mods-latched+ 2)
(defconstant +state-mods-locked+ 4)
(defconstant +state-layout-effective+ 128)
(defconstant +keysym-case-insensitive+ 1)

;; The masks the rest of the tree writes into binding tables.  They are the
;; standard rules' masks -- Shift 1, Mod1 8, Mod4 64 -- and COMPILE-KEYMAP checks
;; that the keymap it compiled agrees, so a layout with an unusual modifier order
;; fails here rather than silently mis-dispatching every Alt binding.
(defparameter +modifier-shift+ 1)
(defparameter +modifier-lock+ 2)
(defparameter +modifier-control+ 4)
(defparameter +modifier-mod1+ 8)
(defparameter +modifier-mod4+ 64)

(defparameter +modifier-names+
  '((:shift . "Shift") (:lock . "Lock") (:control . "Control")
    (:mod1 . "Mod1") (:mod2 . "Mod2") (:mod3 . "Mod3") (:mod4 . "Mod4")
    (:mod5 . "Mod5")))

(define-condition keymap-error (error)
  ((detail :initarg :detail :reader keymap-error-detail))
  (:report (lambda (condition stream)
             (format stream "input: could not compile a keymap~@[: ~A~]"
                     (keymap-error-detail condition)))))

;;; ---------------------------------------------------------------------------
;;; The keymap
;;; ---------------------------------------------------------------------------

(defclass keymap ()
  ((pointer :initarg :pointer :reader keymap-pointer)
   (rules :initarg :rules :initform nil :reader keymap-rules)
   (model :initarg :model :initform nil :reader keymap-model)
   (layout :initarg :layout :initform nil :reader keymap-layout)
   (variant :initarg :variant :initform nil :reader keymap-variant)
   (options :initarg :options :initform nil :reader keymap-options)
   (text :initform nil :accessor %keymap-text)
   (min-keycode :initarg :min-keycode :reader keymap-min-keycode)
   (max-keycode :initarg :max-keycode :reader keymap-max-keycode)
   ;; keysym -> keycode and keycode -> keysym name, built by SCAN-KEYSYMS once
   (codes-by-keysym :initform nil :accessor codes-by-keysym-slot)
   (names-by-code :initform (make-hash-table) :accessor %names-by-code)
   (modifier-masks :initform (make-hash-table) :accessor %modifier-masks)
   (modifier-mask-cache :initform (make-hash-table :test #'equal)
                        :accessor %modifier-mask-cache))
  (:documentation
   "A compiled XKB keymap: the system's layout, resolved.

Everything a compositor asks about a keyboard is a question about this object: what
key produces which keysym, what a keysym is called, which bit a modifier is, and
what the keymap looks like serialized for a client.  The foreign pointer is
reference counted and lives as long as the object (UNREF-KEYMAP is the undo); the
caches are Lisp."))

(defvar *default-keymap* nil
  "The keymap compiled from the environment's layout, built once.")

(defun %context ()
  "A fresh xkbcommon context.  Contexts carry the include paths and the logging
settings; one per keymap is cheap and keeps them independent."
  (let ((context (%context-new 0)))
    (when (cffi:null-pointer-p context)
      (error 'keymap-error :detail "xkb_context_new returned NULL"))
    context))

(defun compile-keymap (&key rules model layout variant options)
  "Compile the keymap the rules say, return a KEYMAP.

Every keyword is a name from the XKB rules files (`evdev`, `pc105`, `us`, `intl`,
...) and every one may be left out: a missing value is the library's default,
which is `XKB_DEFAULT_*` from the environment and then the system's own choice.
That is the whole point of compiling from rules rather than writing the map out --
a user's `XKB_DEFAULT_LAYOUT` configures this compositor the way it configures
every other one."
  (let ((context (%context)))
    (unwind-protect
         (cffi:with-foreign-object (names '(:struct xkb-rule-names))
           (macrolet ((slot (name value)
                        `(setf (cffi:foreign-slot-value
                                names '(:struct xkb-rule-names) ',name)
                               (if ,value
                                   (cffi:foreign-string-alloc ,value)
                                   (cffi:null-pointer))))
                      (free (name)
                        `(let ((pointer (cffi:foreign-slot-value
                                        names '(:struct xkb-rule-names) ',name)))
                           (unless (cffi:null-pointer-p pointer)
                             (cffi:foreign-string-free pointer)))))
             (slot rules rules)
             (slot model model)
             (slot layout layout)
             (slot variant variant)
             (slot options options)
             (unwind-protect
                  (let ((pointer (%keymap-new-from-names context names 0)))
                    (when (cffi:null-pointer-p pointer)
                      (error 'keymap-error
                             :detail (format nil "no keymap for rules=~S layout=~S variant=~S"
                                             rules layout variant)))
                    (make-instance 'keymap
                                   :pointer pointer
                                   :rules rules :model model :layout layout
                                   :variant variant :options options
                                   :min-keycode (%keymap-min-keycode pointer)
                                   :max-keycode (%keymap-max-keycode pointer)))
               (free rules) (free model) (free layout) (free variant) (free options))))
      (%context-unref context))))

(defun keymap-from-string (text &key (format +format-text-v1+))
  "Compile a keymap from TEXT, the form `keymap-text' writes.

Not the usual path -- a compositor compiles from rules -- but it is the only honest
way to check that the text we hand a client is the keymap we think it is: parse it
back and ask the same questions.  It is also how a config that carries a keymap of
its own would load it (D14)."
  (let ((context (%context)))
    (unwind-protect
         (let ((pointer (%keymap-new-from-string context text format 0)))
           (when (cffi:null-pointer-p pointer)
             (error 'keymap-error :detail "the text did not parse as a keymap"))
           (make-instance 'keymap
                          :pointer pointer
                          :layout "from-string"
                          :min-keycode (%keymap-min-keycode pointer)
                          :max-keycode (%keymap-max-keycode pointer)))
      (%context-unref context))))

(defun unref-keymap (keymap)
  "Free the compiled keymap.  Cached answers about it stay in Lisp and stay valid."
  (let ((pointer (keymap-pointer keymap)))
    (unless (cffi:null-pointer-p pointer)
      (%keymap-unref pointer)
      (setf (slot-value keymap 'pointer) (cffi:null-pointer)))
    t))

(defun default-keymap ()
  "The keymap for this session: the environment's layout, compiled once.

A compositor has one keyboard layout for its seat, and the layout comes from the
user's environment (`XKB_DEFAULT_LAYOUT`/`_VARIANT`/`_OPTIONS`) rather than from
this build, which is what makes a German user's `us`-named keymap German.

A environment that does not compile -- a typo in `XKB_DEFAULT_LAYOUT`, a variant the
rules do not have -- falls back to `evdev`/`pc105`/`us` with a line on stderr, and
does not stop the compositor: a keyboard layout is a preference, and refusing to
start over one is worse than starting with the default one.  COMPILE-KEYMAP still
signals for a caller that named the layout itself, because there the mistake is the
caller's."
  (or *default-keymap*
      (setf *default-keymap*
            (handler-case (compile-keymap)
              (keymap-error (condition)
                (format *error-output*
                        "~&input: this session's keymap did not compile (~A); using evdev/pc105/us~%"
                        condition)
                (compile-keymap :rules "evdev" :model "pc105" :layout "us"))))))

(defun keymap-text (keymap)
  "The keymap serialized the way clients want it: XKB text, version 1.

`xkb_keymap_get_as_string` writes the *merged* map -- every include resolved -- so
a client parses it with no access to /usr/share/X11/xkb, which is what the protocol
requires of us.  The C string is copied and freed here: it lives in the library's
allocator, not ours."
  (or (%keymap-text keymap)
      (let ((pointer (%keymap-get-as-string (keymap-pointer keymap) +format-text-v1+)))
        (when (cffi:null-pointer-p pointer)
          (error 'keymap-error :detail "get_as_string returned NULL"))
        (unwind-protect
             (setf (%keymap-text keymap) (cffi:foreign-string-to-lisp pointer))
          (cffi:foreign-funcall "free" :pointer pointer :void)))))

(defun make-keymap (&optional (keymap (default-keymap)))
  "The keymap TEXT clients are given.  Kept as the name the seat asks for."
  (keymap-text keymap))

;;; ---------------------------------------------------------------------------
;;; Names and codes
;;; ---------------------------------------------------------------------------
;;
;; wl_keyboard.key carries an evdev code (the number a device reports), the keymap
;; carries XKB keycodes (evdev + 8), and a binding is written with a keysym name.
;; Two conversions, both mine: code <-> XKB keycode is arithmetic, and keysym <->
;; name is the library's.  The reverse index -- the one a binding needs -- is built
;; once by walking the keymap, because xkbcommon has no "which key is TAB?" call.

(defun keysym-name (keysym)
  "The name of KEYSYM (\"F2\", \"a\", \"Shift_L\"), or NIL for NoSymbol."
  (if (zerop keysym)
      nil
      (cffi:with-foreign-object (buffer :char 128)
        (let ((length (%keysym-get-name keysym buffer 128)))
          (when (plusp length)
            (cffi:foreign-string-to-lisp buffer :count length))))))

(defun keysym (name)
  "The keysym a binding's NAME means, or NIL."
  (let ((value (%keysym-from-name name +keysym-case-insensitive+)))
    (unless (zerop value) value)))

(defun keycode (name &optional (keymap (default-keymap)))
  "The evdev keycode wl_keyboard.key carries for the key called NAME.

NAME is a keysym name (`\"Tab\"`, `\"F2\"`, `\"Shift_L\"`), which is what a binding
table and `inject-key` use.  The lookup goes through the library -- name to keysym,
keysym to keycode -- so it is case-insensitive (`\"f2\"` and `\"F2\"` are the same
key) and a shifted keysym (`\"asciitilde\"`) finds the key that types it."
  (let ((sym (keysym name)))
    (unless sym
      (error "no keysym is named ~S" name))
    (or (gethash sym (codes-by-keysym keymap))
        (error "no key produces the keysym named ~S in this keymap" name))))

(defun xkb-keycode (name &optional (keymap (default-keymap)))
  "The XKB keycode the keymap uses for NAME: evdev + 8."
  (+ 8 (keycode name keymap)))

(defun key-name-for-code (code &optional (keymap (default-keymap)))
  "The keysym name a device's evdev CODE produces at level 0, or NIL.

This is the direction a real keyboard arrives in: libinput reports evdev codes, and
the seat speaks keysym names (INJECT-KEY's argument).  The name comes from the
keymap's *unshifted* level, because a binding names a key and not a key-plus-shift;
a code the keymap has nothing for (a multimedia key) is NIL, which is a fact worth
reporting rather than an error (D56)."
  (when (and (integerp code) (plusp code))
    (multiple-value-bind (cached present-p) (gethash code (%names-by-code keymap))
      (if present-p
          cached
          (setf (gethash code (%names-by-code keymap))
                (let ((syms (keymap-syms keymap (+ 8 code) 0 0)))
                  (and syms (keysym-name (first syms)))))))))

(defun keymap-syms (keymap xkb-code layout level)
  "The keysyms XKB-CODE produces in LAYOUT at LEVEL, as a list, or NIL."
  (cffi:with-foreign-object (syms-out :pointer)
    (let ((count (%key-syms-by-level (keymap-pointer keymap)
                                     xkb-code layout level syms-out)))
      (when (plusp count)
        (let ((pointer (cffi:mem-ref syms-out :pointer)))
          (loop for index below count
                collect (cffi:mem-aref pointer :uint32 index)))))))

(defun codes-by-keysym (keymap)
  "Keysym -> evdev keycode for every keysym the keymap produces, built once.

Keysyms rather than names, because a name is the library's spelling and has to be
parsed back anyway; and levels are walked outside the keycodes so that a key's
unshifted keysym wins over its shifted one: `a' and `A' both come from keycode 30,
and either finds it, but only the unshifted one is what `key-name-for-code' says.

The walk covers the keymap's whole keycode range, which on a current keymap is
wider than evdev's 8..255 -- the extra keys are HID usages a Wayland client cannot
be told about anyway, and letting them into the index costs nothing and surprises
nobody, because a binding names a keysym and not a code."
  (or (codes-by-keysym-slot keymap)
      (let ((table (make-hash-table)))
        (loop for level from 0 below 4
              do (loop for xkb-code from (keymap-min-keycode keymap)
                         to (keymap-max-keycode keymap)
                       do (dolist (sym (keymap-syms keymap xkb-code 0 level))
                            (when (and (plusp sym) (not (gethash sym table)))
                              (setf (gethash sym table) (- xkb-code 8))))))
        (setf (codes-by-keysym-slot keymap) table))))

(defun key-repeats-p (code &optional (keymap (default-keymap)))
  "Whether the keymap says CODE repeats when held."
  (plusp (%key-repeats (keymap-pointer keymap) (+ 8 code))))

;;; ---------------------------------------------------------------------------
;;; Modifiers
;;; ---------------------------------------------------------------------------

(defun keymap-modifier-mask (keymap modifier)
  "The mask MODIFIER (:shift, :control, :mod1, ...) has in KEYMAP.

A property of the keymap, not of the protocol: the standard rules put Shift on bit
0 and Mod1 on bit 3, and a keymap that reordered them would change what every
Alt binding matches, which is why MODIFIER-MASK reads it here."
  (or (gethash modifier (%modifier-masks keymap))
      (setf (gethash modifier (%modifier-masks keymap))
            (let ((name (cdr (assoc modifier +modifier-names+))))
              (unless name
                (error "unknown modifier ~S" modifier))
              (%mod-get-mask (keymap-pointer keymap) name)))))

(defun modifier-mask (modifier &optional (keymap (default-keymap)))
  "The mask MODIFIER has, in the default keymap unless one is given."
  (keymap-modifier-mask keymap modifier))

(defun key-modifier-mask (name &optional (keymap (default-keymap)))
  "The mask pressing NAME sets, or 0 when it sets none.

Asked of the keymap rather than answered from a list of modifier keys: press the
key in a throwaway state and read what became active.  That is the only answer that
survives a layout with a Compose key where another has AltGr, and the answer is
cached per key name because the switcher asks it on every key event."
  (multiple-value-bind (cached present-p) (gethash name (%modifier-mask-cache keymap))
    (if present-p
        cached
        (setf (gethash name (%modifier-mask-cache keymap))
              (let* ((sym (keysym name))
                     (code (and sym (gethash sym (codes-by-keysym keymap)))))
                ;; A name this keymap does not produce sets no modifier, and the
                ;; cache remembers that rather than asking again.
                (if (null code)
                    0
                    (handler-case
                        (let ((state (%state-new (keymap-pointer keymap))))
                          (unwind-protect
                               (progn
                                 (%state-update-key state (+ 8 code) +key-down+)
                                 (%state-serialize-mods
                                  state (logior +state-mods-depressed+
                                                +state-mods-latched+
                                                +state-mods-locked+)))
                            (%state-unref state)))
                      (error () 0))))))))

;;; ---------------------------------------------------------------------------
;;; Modifier state, as the seat reports it
;;; ---------------------------------------------------------------------------
;;
;; wl_keyboard.modifiers carries three masks and a group.  All four are xkb_state's
;; answers: the compositor updates the state with each key event and serializes the
;; component the protocol asks for.  Locked modifiers (Caps Lock) and latching fall
;; out of the keymap's compatibility rules -- there is nothing to special-case.

(defstruct (modifiers (:constructor %make-modifiers (state keymap)))
  (state nil)
  (keymap nil))

(defun make-modifiers (&optional (keymap (default-keymap)))
  "A fresh modifier state for KEYMAP."
  (%make-modifiers (%state-new (keymap-pointer keymap)) keymap))

(defun unref-modifiers (modifiers)
  "Free the state.  The struct stays usable for reading its zeroed masks."
  (when (modifiers-state modifiers)
    (%state-unref (modifiers-state modifiers))
    (setf (modifiers-state modifiers) nil))
  t)

(defun update-modifiers (modifiers name pressed-p)
  "Apply NAME's press or release to MODIFIERS' xkb_state.

The keymap decides what the key does: Shift sets a mask, Caps Lock locks one,
AltGr latches a layout.  This used to be a table of masks in this module; now it is
the keymap's compatibility section, which is what a client's own xkbcommon will
apply to the same codes."
  (when (modifiers-state modifiers)
    (%state-update-key (modifiers-state modifiers)
                       (xkb-keycode name)
                       (if pressed-p +key-down+ +key-up+)))
  modifiers)

(defun modifiers-depressed (modifiers)
  (if (modifiers-state modifiers)
      (%state-serialize-mods (modifiers-state modifiers) +state-mods-depressed+)
      0))

(defun modifiers-latched (modifiers)
  (if (modifiers-state modifiers)
      (%state-serialize-mods (modifiers-state modifiers) +state-mods-latched+)
      0))

(defun modifiers-locked (modifiers)
  (if (modifiers-state modifiers)
      (%state-serialize-mods (modifiers-state modifiers) +state-mods-locked+)
      0))

(defun modifiers-group (modifiers)
  "The effective layout group: which layout a key is currently typed in."
  (if (modifiers-state modifiers)
      (%state-serialize-layout (modifiers-state modifiers) +state-layout-effective+)
      0))

(defun modifiers-keysym (modifiers code)
  "The keysym CODE produces in MODIFIERS' current state, or NIL.

The other half of the key naming: KEY-NAME-FOR-CODE answers the unshifted name a
binding is written with, and this answers what the key types *now* -- which is what
a client would see, and what a future text-input path needs."
  (let ((sym (%state-key-get-one-sym (modifiers-state modifiers) (+ 8 code))))
    (unless (zerop sym) sym)))

(defun modifiers-keysym-name (modifiers code)
  "The name of MODIFIERS-KEYSYM."
  (keysym-name (modifiers-keysym modifiers code)))

;;; ---------------------------------------------------------------------------
;;; The load-time check the struct transcription used to be
;;; ---------------------------------------------------------------------------
;;
;; There is no ABI to check here, so what is checked instead is the assumption the
;; rest of the tree makes: that the standard rules' masks are the ones the binding
;; constants name.  A keymap compiled from a rules file that ordered its modifiers
;; differently would mis-dispatch every Alt binding, and a wrong constant is much
;; harder to find than a failed load.

(defun check-modifier-masks (&optional (keymap (default-keymap)))
  (dolist (pair `((:shift . ,+modifier-shift+) (:control . ,+modifier-control+)
                  (:mod1 . ,+modifier-mod1+) (:mod4 . ,+modifier-mod4+)))
    (let ((actual (keymap-modifier-mask keymap (car pair))))
      (unless (= actual (cdr pair))
        (error 'keymap-error
               :detail (format nil "~A is mask #x~X in this keymap, not #x~X"
                               (car pair) actual (cdr pair))))))
  keymap)

(eval-when (:load-toplevel :execute)
  (check-modifier-masks))

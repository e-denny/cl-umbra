;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; Keybindings: compositor policy consulted before the client (docs/framework.md
;;;; §5).  A binding is (modifiers, key) -> a function, and the key path asks the
;;;; table first: a key that a binding consumes never reaches the focused window.
;;;;
;;;; Keys are named, not numbered, for the same reason cf.input's tables are: the
;;;; name is what a config file will contain (D11), and the evdev code -- the
;;;; number the wire carries -- is derived from it in one place.
;;;;
;;;; Matching is exact on the modifier mask at the moment of the press.  A binding
;;;; on Alt+Escape therefore does not fire when Alt+Shift is held, which is the
;;;; behaviour that makes a binding table predictable; a compositor that wants
;;;; "any of these" adds more bindings.

(in-package #:cl-user)

(in-package #:cf.keybindings)

;;; ---------------------------------------------------------------------------
;;; Bindings and the table
;;; ---------------------------------------------------------------------------

(defclass keybinding ()
  ((key :initarg :key :reader keybinding-key)
   (modifiers :initarg :modifiers :initform 0 :reader keybinding-modifiers)
   (function :initarg :function :reader keybinding-function)
   (description :initarg :description :initform nil :reader keybinding-description))
  (:documentation
   "One binding: KEY (a cf.input key name) pressed with exactly MODIFIERS runs
FUNCTION.  The function is called with no arguments; whatever it needs it closes
over, which is what makes a config file and a REPL session the same thing (D14)."))

(defclass keybinding-table ()
  ((bindings :initarg :bindings :initform nil :accessor keybinding-table-bindings))
  (:documentation "The bindings a compositor consults, newest first."))

(defun make-keybinding-table (&key (bindings nil))
  (make-instance 'keybinding-table :bindings (copy-list bindings)))

(defun add-keybinding (table key function &key (modifiers 0) description)
  "Bind KEY with MODIFIERS to FUNCTION.  A binding for the same pair replaces it."
  (setf (keybinding-table-bindings table)
        (cons (make-instance 'keybinding :key key :modifiers modifiers
                                        :function function
                                        :description description)
              (remove-if (lambda (binding)
                           (and (string-equal key (keybinding-key binding))
                                (= modifiers (keybinding-modifiers binding))))
                         (keybinding-table-bindings table))))
  table)

(defun remove-keybinding (table key &key (modifiers 0))
  "Drop the binding for KEY with MODIFIERS; returns true when one was there."
  (let ((before (length (keybinding-table-bindings table))))
    (setf (keybinding-table-bindings table)
          (remove-if (lambda (binding)
                       (and (string-equal key (keybinding-key binding))
                            (= modifiers (keybinding-modifiers binding))))
                     (keybinding-table-bindings table)))
    (/= before (length (keybinding-table-bindings table)))))

(defun binding-for (table key modifiers)
  "The binding for KEY pressed with exactly MODIFIERS, or NIL."
  (find-if (lambda (binding)
             (and (string-equal key (keybinding-key binding))
                  (= modifiers (keybinding-modifiers binding))))
           (keybinding-table-bindings table)))

(defun dispatch-keybinding (table key modifiers)
  "Run the binding for KEY, if any; return true when one ran.

True means the key was consumed: the focused client must not see it.  A binding
whose function returns NIL still consumed the key -- \"did the function do
something\" and \"did the client get the key\" are different questions, and the
second one is the one that matters here."
  (let ((binding (binding-for table key modifiers)))
    (when binding
      (funcall (keybinding-function binding))
      t)))

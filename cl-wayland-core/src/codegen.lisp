;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; Schema -> Lisp source.
;;;;
;;;; Given a WL-PROTOCOL (usually parsed from XML, but the generators do not
;;;; care where it came from), write a file of DEFINE-* forms that reproduces
;;;; exactly the same schema when loaded, plus the names code wants to mention:
;;;; one package per protocol, a version constant, an opcode constant and a
;;;; generic function per message, a constant per enum entry.
;;;;
;;;; Two properties are load-bearing and tested:
;;;;
;;;;   1. The generated file, loaded, produces metadata identical to the XML's.
;;;;      So codegen is a pure re-spelling of the schema, not a second opinion.
;;;;   2. The generated text is a function of the schema only -- no timestamps,
;;;;      no paths in the body -- so a rebuild is reproducible.
;;;;
;;;; docs/protocol-layer.md §4.

(in-package #:wayland.codegen)

(defparameter *generated-by* "cl-wayland-asdf"
  "Named in the header of every generated file.")

;;; ---------------------------------------------------------------------------
;;; Naming
;;; ---------------------------------------------------------------------------

(defun protocol-package-name (protocol)
  "The package a protocol's symbols live in: wayland, xdg_shell -> XDG-SHELL."
  (string-upcase (lisp-name-of (protocol-name protocol))))

(defun interface-lisp-name (interface)
  (lisp-name-of (interface-name interface)))

(defun message-lisp-name (message)
  (lisp-name-of (message-name message)))

(defun message-symbol-name (interface message)
  "wl-surface.attach"
  (format nil "~A.~A" (interface-lisp-name interface) (message-lisp-name message)))

(defun enum-symbol-name (interface enum)
  (format nil "~A.~A" (interface-lisp-name interface) (lisp-name-of (enum-name enum))))

;;; ---------------------------------------------------------------------------
;;; Emitting
;;; ---------------------------------------------------------------------------

(defun write-lisp-string (string stream)
  "A Lisp string literal, escapes and all.  Descriptions contain newlines and
quotes; the printer knows how to spell them."
  (write string :stream stream :escape t :readably t))

(defparameter +plain-token-characters+
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.+=*/<>!?%&@$")

(defun plain-token-p (name)
  "True when NAME can be written as a bare symbol token and read back as one.

Enum entries named \"90\" are the reason this exists: an unescaped 90 reads as
the number ninety, and the generated file then fails in a confusing place."
  (and (plusp (length name))
       (not (member name '("." "..") :test #'string=))
       (not (digit-char-p (char name 0)))
       (not (char= (char name 0) #\.))
       (every (lambda (character)
                (find character +plain-token-characters+ :test #'char=))
              name)
       (not (find #\| name))
       (not (find #\\ name))))

(defun write-symbol-name (name stream)
  "Write NAME as a symbol token, bar-quoting it when it would not read back."
  (if (plain-token-p name)
      (write-string name stream)
      (progn
        (write-string "|" stream)
        (write-string name stream)
        (write-string "|" stream))))

(defun write-keyword (keyword stream)
  "~A prints a keyword without its colon; the generated file needs the colon."
  (write-string ":" stream)
  (write-string (string-downcase (symbol-name keyword)) stream))

(defun write-argument-spec (argument stream)
  "A single argument in the define-request spelling:
\(buffer :object :interface \"wl_buffer\" :allow-null t)."
  (write-string "(" stream)
  (write-symbol-name (lisp-name-of (arg-name argument)) stream)
  (write-string " " stream)
  (write-keyword (arg-type argument) stream)
  (when (arg-interface argument)
    (format stream " :interface ")
    (write-lisp-string (arg-interface argument) stream))
  (when (arg-allow-null argument)
    (write-string " :allow-null t" stream))
  (when (arg-enum argument)
    (format stream " :enum ")
    (write-lisp-string (arg-enum argument) stream))
  (when (arg-summary argument)
    (write-string " :summary " stream)
    (write-lisp-string (arg-summary argument) stream))
  (write-string ")" stream))

(defun write-documentation-option (documentation stream indent)
  (when documentation
    (format stream "~&~A(:documentation " indent)
    (write-lisp-string documentation stream)
    (write-string ")" stream)))

(defun emit-interface (interface stream)
  (format stream "~&;;; ~A~%~%" (interface-name interface))
  (format stream "(define-interface ")
  (write-symbol-name (interface-lisp-name interface) stream)
  (terpri stream)
  (format stream "    (:version ~D)~%" (interface-version interface))
  (format stream "    (:wire-name ")
  (write-lisp-string (interface-name interface) stream)
  (write-string ")" stream)
  (write-documentation-option (interface-description interface) stream "    ")
  (format stream ")~%"))

(defun emit-enum (interface enum stream)
  (format stream "~&(define-enum ")
  (write-symbol-name (enum-symbol-name interface enum) stream)
  (format stream " ~A~%" (if (enum-bitfield-p enum) "(:bitfield t)" "()"))
  (dolist (entry (enum-entries enum))
    (write-string "  (" stream)
    (write-symbol-name (lisp-name-of (entry-name entry)) stream)
    (format stream " ~D" (entry-value entry))
    (when (> (entry-since entry) 1)
      (format stream " :since ~D" (entry-since entry)))
    (when (entry-summary entry)
      (write-string " :summary " stream)
      (write-lisp-string (entry-summary entry) stream))
    (format stream ")~%"))
  (format stream ")~%~%"))

(defun emit-message (interface message stream)
  (format stream "(~A ("
          (if (eq (message-kind message) :request)
              "define-request"
              "define-event"))
  (write-symbol-name (message-symbol-name interface message) stream)
  (write-string " " stream)
  (write-symbol-name (interface-lisp-name interface) stream)
  (format stream " ~D)~%" (message-opcode message))
  (let ((arguments (message-args message)))
    (if (null arguments)
        (write-string "    ()" stream)
        (progn
          (write-string "    (" stream)
          (loop for argument in arguments
                for tail on arguments
                do (write-argument-spec argument stream)
                   (when (rest tail)
                     (terpri stream)
                     (write-string "     " stream)))
          (write-string ")" stream))))
  (when (> (message-since message) 1)
    (format stream "~&  (:since ~D)" (message-since message)))
  (write-documentation-option (message-description message) stream "  ")
  (format stream ")~%~%"))

;;; ---------------------------------------------------------------------------
;;; The file
;;; ---------------------------------------------------------------------------

(defun protocol-export-names (protocol)
  "Every symbol the generated package exports, in definition order."
  (let ((names '()))
    (dolist (interface (protocol-interfaces protocol))
      (push (interface-lisp-name interface) names)
      (push (string-downcase (version-constant-name (interface-lisp-name interface)))
            names)
      (dolist (enum (interface-enums interface))
        (dolist (entry (enum-entries enum))
          (push (string-downcase
                 (enum-constant-name (interface-lisp-name interface)
                                     (lisp-name-of (enum-name enum))
                                     (lisp-name-of (entry-name entry))))
                names)))
      (dolist (message (append (interface-requests interface)
                               (interface-events interface)))
        (push (message-symbol-name interface message) names)
        (push (string-downcase
               (opcode-constant-name (interface-lisp-name interface)
                                     (message-lisp-name message)))
              names)))
    (nreverse names)))

(defun emit-header (protocol stream)
  (format stream ";;;; Generated from ~A by ~A.  Do not edit.~%"
          (or (protocol-source protocol) "(no source)")
          *generated-by*)
  (format stream ";;;; SPDX-License-Identifier: GPL-3.0-or-later~%")
  (format stream ";;;; Protocol ~S, ~D interface~:P.~%~%"
          (protocol-name protocol)
          (length (protocol-interfaces protocol))))

(defun emit-package (protocol package export stream)
  (format stream "(defpackage #:")
  (write-symbol-name package stream)
  (format stream "~%  (:use #:cl)~%")
  (format stream "  (:import-from #:wayland.protocol~%")
  (format stream "                #:define-interface #:define-enum~%")
  (format stream "                #:define-request #:define-event)~%")
  (when export
    (format stream "  (:export~%")
    (dolist (name (protocol-export-names protocol))
      (format stream "   #:")
      (write-symbol-name name stream)
      (terpri stream))
    (format stream "   )~%"))
  (format stream ")~%~%(in-package #:")
  (write-symbol-name package stream)
  (format stream ")~%~%"))

(defun generate-protocol-text (protocol &key (export t) (package nil))
  "The Lisp source for PROTOCOL, as a string."
  (let ((package (or package (protocol-package-name protocol))))
    (with-output-to-string (stream)
      (emit-header protocol stream)
      (emit-package protocol package export stream)
      (dolist (interface (protocol-interfaces protocol))
        (emit-interface interface stream)
        (dolist (enum (interface-enums interface))
          (emit-enum interface enum stream))
        (dolist (request (interface-requests interface))
          (emit-message interface request stream))
        (dolist (event (interface-events interface))
          (emit-message interface event stream))))))

(defun generate-protocol-file (protocol path &key (export t) (package nil))
  "Write PROTOCOL's Lisp source to PATH.  Returns PATH."
  (ensure-directories-exist path)
  (with-open-file (stream path :direction :output :if-exists :supersede
                               :external-format :utf-8)
    (write-string (generate-protocol-text protocol :export export :package package)
                  stream))
  (finish-output)
  path)

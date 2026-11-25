;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; (:wayland-protocol "wayland/wayland") in a defsystem generates
;;;; wayland/wayland.xml into Lisp, then compiles it the way a normal source
;;;; file is compiled.
;;;;
;;;; The component is a CL-SOURCE-FILE whose source is XML:
;;;;
;;;;   - SOURCE-FILE-TYPE says "xml", so the component's pathname is
;;;;     <parent>/<name>.xml;
;;;;   - PERFORM on COMPILE-OP parses the XML, writes <name>.lisp into the ASDF
;;;;     output cache, and compiles that to exactly the fasl ASDF is expecting
;;;;     for this component (compile-file-pathname of the .xml and the .lisp
;;;;     agree on <name>.fasl, which is why this works without touching
;;;;     output-files);
;;;;   - LOAD-OP is inherited and loads that fasl.
;;;;
;;;; So a rebuild happens when the XML changes, and only then.

(in-package #:cl-user)

(defpackage #:wayland.asdf
  (:use #:cl)
  (:documentation "The ASDF component type for protocol XML.")
  (:export #:wayland-protocol
           #:component-export
           #:component-package))

(in-package #:wayland.asdf)

(defclass wayland-protocol (asdf:cl-source-file)
  ((export :initarg :export :initform t :accessor component-export)
   (package :initarg :package :initform nil :accessor component-package))
  (:documentation
   "A protocol XML file.  :EXPORT (default T) exports the generated symbols;
: PACKAGE overrides the package name, which otherwise comes from the protocol."))

(defmethod asdf:source-file-type ((component wayland-protocol) (module asdf:module))
  "xml")

;; ASDF looks the component type up as a class named after the keyword.  Register
;; under both spellings: the keyword itself, and the name interned in ASDF, which
;; is where cffi-grovel registers its own component types.
(setf (find-class :wayland-protocol) (find-class 'wayland-protocol))
(eval-when (:load-toplevel :execute)
  (setf (find-class (intern "WAYLAND-PROTOCOL" :asdf))
        (find-class 'wayland-protocol)))

(defun generated-source-path (component)
  "Where the generated Lisp goes: beside the compiled file, in the ASDF cache."
  (asdf:apply-output-translations
   (make-pathname :type "lisp" :defaults (asdf:component-pathname component))))

(defmethod asdf:perform ((operation asdf:compile-op) (component wayland-protocol))
  (let* ((source (asdf:component-pathname component))
         (generated (generated-source-path component))
         (fasl (first (asdf:output-files operation component)))
         (protocol (uiop:symbol-call "WAYLAND.PROTOCOL" "PARSE-PROTOCOL-FILE"
                                     source :register nil)))
    (ensure-directories-exist fasl)
    (uiop:symbol-call "WAYLAND.CODEGEN" "GENERATE-PROTOCOL-FILE"
                      protocol generated
                      :export (and (component-export component) t)
                      :package (component-package component))
    (compile-file generated :output-file fasl)
    fasl))

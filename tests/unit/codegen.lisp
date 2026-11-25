;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; Code generation tests.
;;;;
;;;; The important one is the roundtrip: a generated file, loaded, must produce
;;;; exactly the metadata the XML produced.  Codegen is a re-spelling of the
;;;; schema; if it ever becomes a second opinion, this test says so.
;;;;
;;;; The second one is bulk: every vendored protocol generates text that reads
;;;; back as Lisp.  A generator that emits a stray parenthesis for one interface
;;;; in one protocol is a broken build for whoever declares that protocol.

(in-package #:cl-user)

(defpackage #:wayland.test.codegen
  (:use #:cl #:wayland.test)
  (:local-nicknames (#:wp #:wayland.protocol) (#:cg #:wayland.codegen))
  (:documentation "Tests for wayland.codegen and the :wayland-protocol component."))

(in-package #:wayland.test.codegen)

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun tests-directory ()
  (uiop:pathname-directory-pathname
   (asdf:component-pathname (asdf:find-system "cl-wayland-tests"))))

(defun protocol-root ()
  (uiop:subpathname (uiop:pathname-parent-directory-pathname (tests-directory))
                    "protocols/"))

(defun collect-xml-files (directory)
  (append (remove-if-not (lambda (file)
                           (string-equal "xml" (or (pathname-type file) "")))
                         (uiop:directory-files directory))
          (loop for subdirectory in (uiop:subdirectories directory)
                append (collect-xml-files subdirectory))))

(defun parse-file (path)
  (wp:parse-protocol-file path :register nil))

(defun load-generated (protocol)
  "Generate PROTOCOL's source and load it; return the path."
  (uiop:with-temporary-file (:pathname path :type "lisp")
    (cg:generate-protocol-file protocol path :export t)
    (load path)
    path))

(defmacro with-temporary-registry (&body body)
  "Run BODY against empty registry bindings, leaving the real one intact."
  `(let ((wayland.protocol::*interfaces* (make-hash-table :test #'equal))
         (wayland.protocol::*interface-symbols* (make-hash-table :test #'equal)))
     ,@body))

(defun interface-differences (from-xml from-code)
  "Compare two WL-INTERFACE objects field by field."
  (let ((problems '()))
    (labels ((note (control &rest arguments)
               (push (apply #'format nil control arguments) problems))
             (compare-message (a b)
               (unless (eq (wp:message-kind a) (wp:message-kind b))
                 (note "~A ~A: kind" (wp:interface-name from-xml) (wp:message-name a)))
               (unless (= (wp:message-opcode a) (wp:message-opcode b))
                 (note "~A ~A: opcode ~D vs ~D"
                       (wp:interface-name from-xml) (wp:message-name a)
                       (wp:message-opcode a) (wp:message-opcode b)))
               (unless (string= (wp:message-signature a) (wp:message-signature b))
                 (note "~A ~A: signature ~S vs ~S"
                       (wp:interface-name from-xml) (wp:message-name a)
                       (wp:message-signature a) (wp:message-signature b)))
               (unless (= (wp:message-since a) (wp:message-since b))
                 (note "~A ~A: since ~D vs ~D"
                       (wp:interface-name from-xml) (wp:message-name a)
                       (wp:message-since a) (wp:message-since b)))
               (loop for arg-a in (wp:message-args a)
                     for arg-b in (wp:message-args b)
                     do (unless (and (string= (wp:arg-name arg-a) (wp:arg-name arg-b))
                                     (eq (wp:arg-type arg-a) (wp:arg-type arg-b))
                                     (equal (wp:arg-interface arg-a) (wp:arg-interface arg-b))
                                     (eql (wp:arg-allow-null arg-a) (wp:arg-allow-null arg-b))
                                     (equal (wp:arg-enum arg-a) (wp:arg-enum arg-b)))
                          (note "~A ~A: argument ~A differs"
                                (wp:interface-name from-xml) (wp:message-name a)
                                (wp:arg-name arg-a))))))
      (unless (string= (wp:interface-name from-xml) (wp:interface-name from-code))
        (note "name ~S vs ~S" (wp:interface-name from-xml) (wp:interface-name from-code)))
      (unless (= (wp:interface-version from-xml) (wp:interface-version from-code))
        (note "~A: version ~D vs ~D" (wp:interface-name from-xml)
              (wp:interface-version from-xml) (wp:interface-version from-code)))
      (unless (= (length (wp:interface-requests from-xml))
                 (length (wp:interface-requests from-code)))
        (note "~A: ~D requests vs ~D" (wp:interface-name from-xml)
              (length (wp:interface-requests from-xml))
              (length (wp:interface-requests from-code))))
      (unless (= (length (wp:interface-events from-xml))
                 (length (wp:interface-events from-code)))
        (note "~A: ~D events vs ~D" (wp:interface-name from-xml)
              (length (wp:interface-events from-xml))
              (length (wp:interface-events from-code))))
      (loop for a in (wp:interface-requests from-xml)
            for b in (wp:interface-requests from-code)
            do (compare-message a b))
      (loop for a in (wp:interface-events from-xml)
            for b in (wp:interface-events from-code)
            do (compare-message a b))
      (dolist (enum (wp:interface-enums from-xml))
        (let ((other (find (wp:enum-name enum) (wp:interface-enums from-code)
                           :key #'wp:enum-name :test #'string=)))
          (if (null other)
              (note "~A: enum ~A missing" (wp:interface-name from-xml) (wp:enum-name enum))
              (progn
                (unless (eql (wp:enum-bitfield-p enum) (wp:enum-bitfield-p other))
                  (note "~A ~A: bitfield" (wp:interface-name from-xml) (wp:enum-name enum)))
                (loop for entry in (wp:enum-entries enum)
                      for other-entry in (wp:enum-entries other)
                      do (unless (and (string= (wp:entry-name entry) (wp:entry-name other-entry))
                                      (= (wp:entry-value entry) (wp:entry-value other-entry)))
                           (note "~A ~A: entry ~A differs"
                                 (wp:interface-name from-xml) (wp:enum-name enum)
                                 (wp:entry-name entry))))))))
      (nreverse problems))))

;;; ---------------------------------------------------------------------------
;;; The text
;;; ---------------------------------------------------------------------------

(deftest generated-text-has-the-expected-shape
  (let* ((protocol (parse-file (merge-pathnames
                                "wayland-protocols/stable/xdg-shell/xdg-shell.xml"
                                (protocol-root))))
         (text (cg:generate-protocol-text protocol))
         (package (cg:protocol-package-name protocol))
         (toplevel (find "xdg_toplevel" (wp:protocol-interfaces protocol)
                         :key #'wp:interface-name :test #'string=))
         (set-title (find "set_title" (wp:interface-requests toplevel)
                          :key #'wp:message-name :test #'string=)))
    (is (string= "XDG-SHELL" package))
    (is (search "(defpackage #:XDG-SHELL" text))
    (is (search "#:define-request" text))
    (is (search "(define-interface xdg-toplevel" text))
    (is (search (format nil "(:version ~D)" (wp:interface-version toplevel)) text))
    (let ((state (find "state" (wp:interface-enums toplevel)
                       :key #'wp:enum-name :test #'string=)))
      (is (search (format nil "(define-enum xdg-toplevel.state ~A"
                          (if (wp:enum-bitfield-p state) "(:bitfield t)" "()"))
                  text)))
    (is (find-if #'wp:enum-bitfield-p
                 (loop for interface in (wp:protocol-interfaces protocol)
                       append (wp:interface-enums interface)))
        "xdg-shell has bitfield enums, so the bitfield branch is exercised")
    (is (search (format nil "(define-request (xdg-toplevel.set-title xdg-toplevel ~D)"
                        (wp:message-opcode set-title))
                text))
    (is (search "(title :string" text))
    (is (search "(define-event (xdg-toplevel.configure xdg-toplevel 0)" text))
    (is (search ":allow-null t" text)
        "a nullable object argument keeps its nullability")
    (is (search "#:+xdg-toplevel-state-maximized+" text))
    (is (search "#:xdg-toplevel.set-title" text))))

(deftest generation-is-deterministic
  (let* ((path (merge-pathnames "wayland/wayland.xml" (protocol-root)))
         (protocol (parse-file path)))
    (is (string= (cg:generate-protocol-text protocol)
                 (cg:generate-protocol-text protocol)))))

(deftest numeric-enum-entries-are-escaped
  ;; wl_output.transform's entries are named "90", "180", "270"; unescaped they
  ;; read as numbers and the generated file dies in a confusing place.
  (let* ((protocol (parse-file (merge-pathnames "wayland/wayland.xml" (protocol-root))))
         (text (cg:generate-protocol-text protocol)))
    (is (search "(|90| 1 :summary" text))
    (is (search "(|180| 2 :summary" text))))

;;; ---------------------------------------------------------------------------
;;; The roundtrip
;;; ---------------------------------------------------------------------------

(deftest generated-code-reproduces-the-schema
  "Load the generated source for a protocol and compare it with the XML."
  (dolist (relative '("wayland/wayland.xml"
                      "wayland-protocols/stable/xdg-shell/xdg-shell.xml"))
    (let* ((path (merge-pathnames relative (protocol-root)))
           (protocol (parse-file path))
           (problems '()))
      (load-generated protocol)
      (dolist (interface (wp:protocol-interfaces protocol))
        (let ((generated (wp:find-interface (wp:interface-name interface))))
          (if (null generated)
              (push (format nil "~A: not registered after loading"
                            (wp:interface-name interface))
                    problems)
              (setf problems
                    (append (interface-differences interface generated) problems)))))
      (dolist (problem (nreverse problems))
        (format *error-output* "~&  codegen: ~A: ~A~%" relative problem))
      (is (null problems)
          (format nil "generated code reproduces ~A" relative)))))

(deftest generated-code-defines-the-convenient-names
  (let* ((protocol (parse-file (merge-pathnames "wayland/wayland.xml" (protocol-root))))
         (package-name (cg:protocol-package-name protocol)))
    (load-generated protocol)
    (flet ((lookup (name) (find-symbol name package-name)))
      (is (fboundp (lookup "WL-SURFACE.ATTACH"))
          "every message is a generic function to specialise")
      (is (= 7 (symbol-value (lookup "+WL-SURFACE-VERSION+"))))
      (is (= 1 (symbol-value (lookup "+WL-SURFACE-ATTACH+"))))
      (is (= 0 (symbol-value (lookup "+WL-SURFACE-ERROR-INVALID-SCALE+"))))
      (is (= 1 (symbol-value (lookup "+WL-OUTPUT-TRANSFORM-90+"))))
      (is (typep (fdefinition (lookup "WL-DISPLAY.SYNC")) 'generic-function)))))

(deftest generated-code-keeps-registry-bind-on-the-wire
  (let* ((protocol (parse-file (merge-pathnames "wayland/wayland.xml" (protocol-root))))
         (package-name (cg:protocol-package-name protocol)))
    (load-generated protocol)
    (let* ((registry (wp:find-interface "wl_registry"))
           (bind (first (wp:interface-requests registry))))
      (is (string= "usun" (wp:message-signature bind)))
      (is (equal '("name" "interface" "version" "id")
                 (mapcar #'wp:arg-name (wp:message-args bind))))
      (is (fboundp (find-symbol "WL-REGISTRY.BIND" package-name))))))

(deftest defining-one-interface-twice-at-different-versions-is-refused
  (with-temporary-registry
    (wp::%define-interface 'zz-test-interface 1 "zz_test_interface" "")
    (is (wp:find-interface "zz_test_interface"))
    (signals wp:conflicting-interface
      (wp::%define-interface 'zz-test-interface 2 "zz_test_interface" ""))
    (is (= 1 (wp:interface-version (wp:find-interface "zz_test_interface")))
        "the first definition survives a refused one")))

;;; ---------------------------------------------------------------------------
;;; Every protocol generates readable Lisp
;;; ---------------------------------------------------------------------------

(deftest every-vendored-protocol-generates-readable-lisp
  (let ((files (sort (collect-xml-files (protocol-root)) #'string< :key #'namestring))
        (failures '()))
    (is (>= (length files) 60))
    (dolist (file files)
      (handler-case
          (let* ((protocol (parse-file file))
                 (text (cg:generate-protocol-text protocol))
                 (package (make-package (gensym "CODEGEN-READ-"))))
            (unwind-protect
                 (let ((*package* package)
                       (forms 0))
                   (is (plusp (length text)))
                   (with-input-from-string (stream text)
                     (loop for form = (read stream nil :eof)
                           until (eq form :eof)
                           do (incf forms)))
                   (is (plusp forms)))
              (delete-package package)))
        (error (condition)
          (push (format nil "~A: ~A" (file-namestring file) condition) failures))))
    (dolist (failure (nreverse failures))
      (format *error-output* "~&  codegen: ~A~%" failure))
    (is (null failures) "every vendored protocol generates readable Lisp")))

;;; ---------------------------------------------------------------------------
;;; The ASDF component did its job
;;; ---------------------------------------------------------------------------

(deftest the-wayland-protocol-component-generated-and-loaded
  ;; cl-wayland-tests depends on cl-wayland-protocols, which uses the
  ;; :WAYLAND-PROTOCOL component for these two files.
  (is (fboundp (find-symbol "WL-DISPLAY.SYNC" "WAYLAND")))
  (is (fboundp (find-symbol "XDG-TOPLEVEL.SET-TITLE" "XDG-SHELL")))
  (is (typep (wp:find-interface "xdg_toplevel") 'wp:wl-interface)))

;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; Gate clause: every vendored protocol XML generates Lisp that compiles.
;;;;
;;;; The unit suite reads all 69 generated files (tests/unit/codegen.lisp) but
;;;; only compiles the two protocols cl-wayland-protocols declares.  Loading all
;;;; of them into one image is unsafe by design -- several supply different
;;;; versions of the same interface -- but *compiling* is a local operation: each
;;;; file gets a package of its own, and nothing calls into the registry.
;;;;
;;;; Reports one line per protocol and a summary; the exit status is the verdict.
;;;; Loaded by scripts/gate.sh after cl-wayland-core is available.

(in-package #:cl-user)

(defpackage #:wayland.gate.protocols
  (:use #:cl)
  (:local-nicknames (#:wp #:wayland.protocol) (#:cg #:wayland.codegen))
  (:export #:compile-all
           #:collect-xml-files))

(in-package #:wayland.gate.protocols)

(defun collect-xml-files (directory)
  (append (remove-if-not (lambda (file)
                           (string-equal "xml" (or (pathname-type file) "")))
                         (uiop:directory-files directory))
          (loop for subdirectory in (uiop:subdirectories directory)
                append (collect-xml-files subdirectory))))

(defun compile-one (file index output-directory)
  "Parse FILE, generate its Lisp into OUTPUT-DIRECTORY and compile that.

Returns (values ok-p description).  Nothing is loaded, so the image's registry is
untouched and duplicate interface versions across protocols cannot clash."
  (handler-case
      (let* ((protocol (wp:parse-protocol-file file :register nil))
             (package (format nil "GATE-PROTOCOL-~D" index))
             (source (merge-pathnames (format nil "gate-~D.lisp" index)
                                      output-directory))
             (fasl (merge-pathnames (format nil "gate-~D.fasl" index)
                                    output-directory)))
        (with-open-file (stream source :direction :output
                                       :if-exists :supersede
                                       :external-format :utf-8)
          (write-string (cg:generate-protocol-text protocol :package package) stream))
        (multiple-value-bind (path warnings-p failure-p)
            (compile-file source :output-file fasl :verbose nil :print nil)
          (when (or warnings-p failure-p)
            (return-from compile-one
              (values nil (format nil "compiled with ~:[a failure~;warnings~]"
                                  warnings-p))))
          (values (and path t)
                  (format nil "~D interface~:P"
                          (length (wp:protocol-interfaces protocol))))))
    (error (condition)
      (values nil (princ-to-string condition)))))

(defun compile-all (&key (root (asdf:system-relative-pathname
                                "cl-wayland-protocols" "../protocols/"))
                         (stream *standard-output*)
                         (error-stream *error-output*))
  "Compile every protocol under ROOT.  Returns true when all of them compiled."
  (let ((files (sort (collect-xml-files root) #'string< :key #'namestring))
        (index 0)
        (failed '()))
    (when (zerop (length files))
      (format error-stream "~&no protocol XML found under ~A~%" root)
      (return-from compile-all nil))
    (let ((output (merge-pathnames
                   (format nil "cl-wayland-gate-~36R/" (random most-positive-fixnum))
                   (uiop:temporary-directory))))
      (ensure-directories-exist output)
      (unwind-protect
           (dolist (file files)
             (multiple-value-bind (ok-p description)
                 (compile-one file (incf index) output)
               (unless ok-p
                 (push (cons file description) failed))
               (format stream "  ~:[FAIL~;ok  ~] ~A~@[ (~A)~]~%"
                       ok-p
                       (enough-namestring file
                                          (uiop:ensure-directory-pathname root))
                       description)))
        (uiop:delete-directory-tree output :validate t :if-does-not-exist :ignore)))
    (format stream "~&~D of ~D protocol~:P compiled~%"
            (- (length files) (length failed)) (length files))
    (dolist (failure (reverse failed))
      (format error-stream "~&protocol ~A: ~A~%"
              (file-namestring (car failure)) (cdr failure)))
    (null failed)))

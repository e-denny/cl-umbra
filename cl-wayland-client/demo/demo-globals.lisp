;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; demo-globals: connect to the compositor named by the environment, list its
;;;; globals, exit.  The phase-0 walking skeleton (docs/roadmap.md).
;;;;
;;;; The output is deliberately wayland-info's line format -- name field 42 wide,
;;;; then "', version:  6, name:  1" -- so the phase-0 gate can diff the two
;;;; instead of eyeballing them:
;;;;
;;;;   interface: 'wl_compositor',   version:  5, name:  5
;;;;
;;;; Nothing is bound: this program only reads the registry and completes one
;;;; sync roundtrip.  It never sends a request the compositor must react to
;;;; beyond that, and it never draws.

(in-package #:cl-user)

(defpackage #:wayland.client.demo
  (:use #:cl #:wayland.client)
  (:documentation "The phase-0 demo: print the live session's globals.")
  (:export #:run #:main))

(in-package #:wayland.client.demo)

(defun collect-globals (registry)
  "Install a hook on REGISTRY; return a function yielding the current globals.

The hook is installed before the roundtrip, so the burst of global events the
server sends in response to get_registry is collected, and global_remove keeps
the list honest for a long-lived client."
  (let ((globals '()))
    (push (lambda (event &rest arguments)
            (ecase event
              (:global
               (destructuring-bind (name interface version) arguments
                 (push (list name interface version) globals)))
              (:global-remove
               (destructuring-bind (name) arguments
                 (setf globals (delete name globals :key #'first))))))
          (proxy-hooks registry))
    (lambda () (sort (copy-list globals) #'< :key #'first))))

(defun print-globals (globals stream)
  "One line per global, in wayland-info's format: the name field is 42 wide, so
the two programs' output can be compared with diff and nothing else."
  (dolist (global (sort (copy-list globals) #'< :key #'first))
    (destructuring-bind (name interface version) global
      ;; The padding sits after "'," so the closing quote hugs the name, exactly
      ;; as wayland-info prints it; 43 - name-length keeps "version:" at
      ;; column 57 for every name that fits, and one space for the rest.
      (format stream "interface: '~A',~Aversion: ~2D, name: ~2D~%"
              interface
              (make-string (max 1 (- 43 (length interface))) :initial-element #\Space)
              version name))))

(defun run (&key (stream *standard-output*) (error-stream *error-output*))
  "Print the session's globals; return 0 on success, 1 on any failure."
  (handler-case
      (with-open-display (display)
        (let* ((registry (wl-display.get-registry display))
               (current (collect-globals registry)))
          (roundtrip display)
          (let ((globals (funcall current)))
            (print-globals globals stream)
            (format error-stream "~&~D global~:P~%" (length globals))
            0)))
    (display-error (condition)
      (format error-stream "~&demo-globals: ~A~%" condition)
      1)
    (client-error (condition)
      (format error-stream "~&demo-globals: ~A~%" condition)
      1)
    (wayland.ffi:io-error (condition)
      (format error-stream "~&demo-globals: ~A~%" condition)
      1)))

(defun main ()
  "Entry point for the built binary and for `sbcl --eval`."
  (uiop:quit (run)))

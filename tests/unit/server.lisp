;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; Server tests: a real socket in a real directory, a real client on the other
;;;; end, and raw messages where a test needs to break the protocol on purpose.
;;;;
;;;; Two ends of our own stack in one image need a pump, because neither side may
;;;; block: the client's reactor gets a 1 ms repeating timer that runs one server
;;;; cycle, so an ordinary (ROUNDTRIP CLIENT) drives both.  That is a test
;;;; arrangement, not the compositor's design -- the server itself has one loop
;;;; and no threads (D9).

(in-package #:cl-user)

(defpackage #:wayland.test.server
  (:use #:cl #:rove)
  (:local-nicknames (#:srv #:wayland.server)
                    (#:wc #:wayland.client)
                    (#:ffi #:wayland.ffi)
                    (#:io #:wayland.io)
                    (#:wire #:wayland.wire)
                    (#:reactor #:wayland.reactor))
  (:documentation "Tests for wayland.server: socket, accept, ids, dispatch, teardown."))

(in-package #:wayland.test.server)

;;; ---------------------------------------------------------------------------
;;; Fixtures
;;; ---------------------------------------------------------------------------

(defvar *directory-counter* 0)

(defun make-test-directory ()
  "A private directory to put a socket in, the way $XDG_RUNTIME_DIR is private."
  (let ((path (format nil "/tmp/cl-wayland-server-test-~D-~D/"
                      (get-universal-time) (incf *directory-counter*))))
    (ensure-directories-exist path)
    (ffi:chmod-path (string-right-trim "/" path) #o700)
    path))

(defun clean-test-directory (directory)
  (handler-case (uiop:delete-empty-directory directory)
    (error () nil)))

(defmacro with-directory ((directory) &body body)
  "A private directory, and a quiet server: connect/disconnect chatter at :info
would drown a test run, and the assertions are the evidence."
  `(let ((,directory (make-test-directory))
         (srv:*log-level* :warn))
     (unwind-protect (locally ,@body)
       (clean-test-directory ,directory))))

(defmacro with-display ((display &rest arguments) &body body)
  "A bare display: socket and accept loop, no globals."
  `(with-directory (directory)
     (let ((,display (srv:make-display :display-name "test-0"
                                       :runtime-dir directory
                                       ,@arguments)))
       (unwind-protect (locally ,@body)
         (srv:close-display ,display)))))

(defmacro with-demo ((display &rest arguments) &body body)
  "The demo display: wl_compositor and wl_output."
  `(with-directory (directory)
     (let ((,display (srv:make-demo-display :display-name "test-0"
                                            :runtime-dir directory
                                            ,@arguments)))
       (unwind-protect (locally ,@body)
         (srv:close-display ,display)))))

(defmacro with-loopback ((client display) &body body)
  "CLIENT connected to DISPLAY, with DISPLAY pumped from CLIENT's reactor."
  (let ((reactor (gensym "REACTOR")) (timer (gensym "TIMER")))
    `(let* ((,client (wc:connect :path (srv:display-socket-path ,display)))
            (,reactor (wc:display-reactor ,client))
            (,timer (reactor:add-timer
                     ,reactor 0.001
                     (lambda (timer)
                       (declare (ignore timer))
                       (srv:run-once ,display :timeout 0))
                     :repeat 0.001)))
       (unwind-protect (locally ,@body)
         (reactor:cancel-timer ,reactor ,timer)
         (wc:disconnect ,client)))))

;;; ---------------------------------------------------------------------------
;;; Pumps and raw clients
;;; ---------------------------------------------------------------------------

(defun run-server (display &key (cycles 8) (timeout 0.01))
  "Give DISPLAY a few cycles.  Level-triggered epoll means nothing is lost."
  (loop repeat cycles do (srv:run-once display :timeout timeout)))

(defun raw-connect (display)
  "A connection with no protocol code at all, so a test can write anything."
  (let ((fd (ffi:connect-unix-socket (srv:display-socket-path display))))
    (run-server display)
    fd))

(defun only-client (display)
  (first (srv:display-clients display)))

(defun send-message (fd object-id opcode &optional writer)
  "Write one message, with WRITER filling in the arguments."
  (let ((buffer (wire:make-message-buffer)))
    (let ((start (wire:begin-message buffer object-id opcode)))
      (when writer (funcall writer buffer))
      (wire:end-message buffer start))
    (io:flush-buffer fd buffer)))

(defun receive-octets (fd &key (size 8192))
  (let ((octets (make-array size :element-type '(unsigned-byte 8))))
    (multiple-value-bind (count fds truncated-p eof-p)
        (ffi:receive-with-ancillary fd octets 0 size :fds-max 8)
      (dolist (descriptor fds) (ffi:close-fd descriptor))
      (ok (not truncated-p) "no descriptor truncation expected here")
      (values (subseq octets 0 count) eof-p))))

(defun parse-messages (octets)
  "Every complete message in OCTETS, as (object-id opcode reader)."
  (let ((messages '())
        (start 0))
    (loop
      (multiple-value-bind (object-id opcode size)
          (wire:decode-header octets :start start)
        (unless (and object-id (<= (+ start size) (length octets)))
          (return (nreverse messages)))
        (push (list object-id opcode
                    (wire:make-reader octets
                                      :start (+ start wire:+header-size+)
                                      :end (+ start size)))
              messages)
        (incf start size)))))

(defun read-events (fd &key (timeout 0.5))
  "Read until at least one whole message arrives, or TIMEOUT passes."
  (let ((deadline (+ (reactor:monotonic-now) timeout)))
    (loop
      (multiple-value-bind (octets eof-p) (receive-octets fd)
        (let ((messages (parse-messages octets)))
          (when (or messages eof-p)
            (return messages))))
      (when (>= (reactor:monotonic-now) deadline)
        (return nil)))))

(defun fd-count ()
  "Open descriptors of this process, which is how a leak shows up."
  (length (directory (pathname "/proc/self/fd/*"))))

(defun error-reply (events)
  "The one wl_display.error in EVENTS as (object-id code message), after asserting
that there is exactly one message and that it is an error."
  (ok (= 1 (length events)) "exactly one reply expected")
  (destructuring-bind (id opcode reader) (first events)
    (ok (= 1 id) "wl_display.error arrives on object 1")
    (ok (= 0 opcode) "wl_display.error is opcode 0")
    (list (wire:read-uint reader) (wire:read-uint reader) (wire:read-string reader))))

;;; ---------------------------------------------------------------------------
;;; The socket
;;; ---------------------------------------------------------------------------

(deftest socket-and-lock-exist-with-private-modes
  (with-display (display)
    (let* ((path (srv:display-socket-path display))
           (lock (concatenate 'string path ".lock"))
           (mode (lambda (file)
                   (string-trim '(#\Newline #\Space)
                                (uiop:run-program (list "stat" "-c" "%a" file)
                                                  :output :string)))))
      (ok (uiop:file-exists-p path))
      (ok (uiop:file-exists-p lock))
      (ok (equal "700" (funcall mode path)) "only this user may connect")
      (ok (equal "600" (funcall mode lock)))
      (ok (= (ffi:process-id)
             (parse-integer (uiop:read-file-string lock) :junk-allowed t))
          "the lock file names the server that holds it"))))

(deftest a-second-server-on-the-same-name-is-refused
  (with-directory (directory)
    (let ((first (srv:make-display :display-name "test-0" :runtime-dir directory)))
      (unwind-protect
           (ok (signals (srv:make-display :display-name "test-0" :runtime-dir directory)
                        'srv:socket-in-use))
        (srv:close-display first)))))

(deftest closing-removes-the-socket-and-the-lock
  (with-directory (directory)
    (let* ((display (srv:make-display :display-name "test-0" :runtime-dir directory))
           (path (srv:display-socket-path display))
           (lock (concatenate 'string path ".lock")))
      (srv:close-display display)
      (ok (not (uiop:file-exists-p path)))
      (ok (not (uiop:file-exists-p lock)))
      (ok (srv:display-closed-p display))
      (ok (srv:close-display display) "close is idempotent"))))

(deftest a-stale-socket-is-replaced
  ;; A crashed server leaves the socket file but no lock.  The next server must
  ;; take the name rather than fail: the lock is the authority, not the file.
  (with-directory (directory)
    (let* ((crashed (srv:make-display :display-name "test-0" :runtime-dir directory))
           (path (srv:display-socket-path crashed))
           (replacement nil))
      (unwind-protect
           (progn
             (uiop:delete-file-if-exists (concatenate 'string path ".lock"))
             (setf replacement (srv:make-display :display-name "test-0"
                                                 :runtime-dir directory))
             (ok (uiop:file-exists-p (srv:display-socket-path replacement)))
             (ok (string= path (srv:display-socket-path replacement))))
        (when replacement (srv:close-display replacement))
        (uiop:delete-file-if-exists path)
        (srv:close-display crashed)))))

(deftest accept-records-peer-credentials
  (with-display (display)
    (let ((fd (ffi:connect-unix-socket (srv:display-socket-path display))))
      (unwind-protect
           (progn
             (run-server display)
             (ok (= 1 (length (srv:display-clients display))))
             (let ((client (only-client display)))
               (ok (= (ffi:process-id) (srv:client-pid client)))
               (ok (= (ffi:effective-uid) (srv:client-uid client)))
               (ok (integerp (srv:client-gid client)))
               (ok (ffi:fd-cloexec-p (srv:client-fd client))
                   "an accepted descriptor must never leak into a child")))
        (ffi:close-fd fd)))))

(deftest accept-budget-is-honoured
  ;; One readable event must not accept forever: a connect storm may not starve
  ;; the clients that are already connected.
  (with-display (display :accept-budget 2)
    (let ((fds (loop repeat 5
                     collect (ffi:connect-unix-socket (srv:display-socket-path display)))))
      (unwind-protect
           (progn
             (srv:run-once display :timeout 0.01)
             (ok (<= (length (srv:display-clients display)) 2))
             (run-server display)
             (ok (= 5 (length (srv:display-clients display)))
                 "the rest arrive on later cycles; level-triggered epoll keeps them"))
        (dolist (fd fds) (ffi:close-fd fd))))))

;;; ---------------------------------------------------------------------------
;;; Globals, bind, initial events
;;; ---------------------------------------------------------------------------

(deftest client-sees-globals-in-registration-order
  (with-demo (display)
    (with-loopback (client display)
      (let* ((registry (wc:wl-display.get-registry client))
             (globals '()))
        (push (lambda (event &rest arguments)
                (when (eq event :global)
                  (push arguments globals)))
              (wc:proxy-hooks registry))
        (ok (wc:roundtrip client))
        (ok (equal '((1 "wl_compositor" 1) (2 "wl_output" 4))
                   (reverse globals)))))))

(deftest get-registry-may-be-called-more-than-once
  (with-demo (display)
    (with-loopback (client display)
      (let ((first (wc:wl-display.get-registry client))
            (second (wc:wl-display.get-registry client))
            (first-count 0)
            (second-count 0))
        (ok (/= (wc:proxy-id first) (wc:proxy-id second)))
        (push (lambda (event &rest arguments)
                (declare (ignore arguments))
                (when (eq event :global) (incf first-count)))
              (wc:proxy-hooks first))
        (push (lambda (event &rest arguments)
                (declare (ignore arguments))
                (when (eq event :global) (incf second-count)))
              (wc:proxy-hooks second))
        (wc:roundtrip client)
        (ok (= 2 first-count) "each registry gets its own copy of the list")
        (ok (= 2 second-count))))))

(deftest bound-output-sends-its-initial-events-in-order
  (with-demo (display)
    (with-loopback (client display)
      (let ((registry (wc:wl-display.get-registry client))
            (events '()))
        (wc:roundtrip client)
        (let ((output (wc:wl-registry.bind registry 2 "wl_output" 4)))
          (push (lambda (event &rest arguments)
                  (push (cons event arguments) events))
                (wc:proxy-hooks output))
          (ok (wc:roundtrip client)))
        (ok (equal '(:geometry :mode :scale :name :description :done)
                   (mapcar #'car (reverse events)))
            "geometry, mode, scale, name, description, then done (docs/protocol-layer.md §8)")))))

(deftest a-version-one-output-gets-no-newer-events
  (with-demo (display)
    (with-loopback (client display)
      (let ((registry (wc:wl-display.get-registry client))
            (events '()))
        (wc:roundtrip client)
        (let ((output (wc:wl-registry.bind registry 2 "wl_output" 1)))
          (ok (= 1 (wc:proxy-version output)))
          (push (lambda (event &rest arguments)
                  (declare (ignore arguments))
                  (push event events))
                (wc:proxy-hooks output))
          (wc:roundtrip client))
        (ok (equal '(:geometry :mode) (reverse events))
            "done, scale, name and description are newer than version 1")))))

(defmacro expect-bind-failure ((name interface version) display)
  "Bind something invalid on a fresh client; the server must say so and hang up."
  `(with-loopback (fresh ,display)
     (let ((registry (wc:wl-display.get-registry fresh)))
       (wc:roundtrip fresh)
       (ok (signals (progn (wc:wl-registry.bind registry ,name ,interface ,version)
                           (wc:roundtrip fresh))
                    'wc:display-error)
           (format nil "binding ~A as ~A at version ~D must fail"
                   ,name ,interface ,version))
       (run-server ,display)
       (ok (null (srv:display-clients ,display))
           "the client that broke the protocol is gone"))))

(deftest bind-validates-what-the-client-asked-for
  (with-demo (display)
    (expect-bind-failure (1 "wl_output" 1) display)       ; interface mismatch
    (expect-bind-failure (99 "wl_compositor" 1) display)  ; no such global
    ;; The server survived both: a fresh client still gets a roundtrip.
    (with-loopback (fresh display)
      (ok (wc:roundtrip fresh)))))

(deftest a-version-above-the-globals-is-refused
  ;; Our client clamps the version it asks for (docs/protocol-layer.md §6), so
  ;; the only way to ask for something too new is to say it on the wire.
  (with-demo (display)
    (let ((fd (raw-connect display)))
      (unwind-protect
           (progn
             (send-message fd 1 1 (lambda (buffer) (wire:put-new-id buffer 2)))
             (run-server display)
             (read-events fd)
             (send-message fd 2 0
                           (lambda (buffer)
                             (wire:put-uint buffer 2)
                             (wire:put-string buffer "wl_output")
                             (wire:put-uint buffer 5)
                             (wire:put-new-id buffer 3)))
             (run-server display)
             (destructuring-bind (object-id code message) (error-reply (read-events fd))
               (ok (= 2 object-id))
               (ok (= srv:+error-invalid-object+ code))
               (ok (search "cannot bind" message)))
             (ok (null (srv:display-clients display))))
        (ffi:close-fd fd)))))

(deftest global-added-later-is-announced-before-the-next-sync
  (with-demo (display)
    (with-loopback (client display)
      (let ((registry (wc:wl-display.get-registry client))
            (globals '()))
        (push (lambda (event &rest arguments)
                (when (eq event :global) (push arguments globals)))
              (wc:proxy-hooks registry))
        (wc:roundtrip client)
        (srv:add-global display :interface "wl_shm" :version 1)
        (ok (wc:roundtrip client))
        (ok (equal '((1 "wl_compositor" 1) (2 "wl_output" 4) (3 "wl_shm" 1))
                   (reverse globals)))))))

(deftest global-removed-is-announced
  (with-demo (display)
    (with-loopback (client display)
      (let ((registry (wc:wl-display.get-registry client))
            (removed '()))
        (push (lambda (event &rest arguments)
                (when (eq event :global-remove) (push arguments removed)))
              (wc:proxy-hooks registry))
        (wc:roundtrip client)
        (srv:remove-global display (srv:find-global display 2))
        (ok (wc:roundtrip client))
        (ok (equal '((2)) removed))))))

;;; ---------------------------------------------------------------------------
;;; Ids, sync, delete_id
;;; ---------------------------------------------------------------------------

(deftest sync-answers-with-done-then-delete-id
  (with-demo (display)
    (let ((fd (raw-connect display)))
      (unwind-protect
           (progn
             ;; wl_display.sync is opcode 0 and carries a new_id: the client chose 2.
             (send-message fd 1 0 (lambda (buffer) (wire:put-new-id buffer 2)))
             (run-server display)
             (let ((events (read-events fd)))
               (ok (= 2 (length events)))
               (destructuring-bind ((id1 op1 reader1) (id2 op2 reader2)) events
                 (ok (= 2 id1) "wl_callback.done, on the callback the client named")
                 (ok (= 0 op1))
                 (ok (zerop (wire:read-uint reader1)) "callback data 0 for sync")
                 (ok (= 1 id2) "wl_display.delete_id, on wl_display")
                 (ok (= 1 op2))
                 (ok (= 2 (wire:read-uint reader2))
                     "the callback id was the client's, so it comes back")))
             (ok (not (srv:client-closed-p (only-client display)))))
        (ffi:close-fd fd)))))

(deftest a-released-id-is-reused
  (with-demo (display)
    (let ((fd (raw-connect display)))
      (unwind-protect
           (progn
             (dotimes (round 2)
               (send-message fd 1 0 (lambda (buffer) (wire:put-new-id buffer 2)))
               (run-server display)
               (let ((events (read-events fd)))
                 (ok (= 2 (length events))
                     (format nil "round ~D: done and delete_id" (1+ round)))
                 (ok (not (srv:client-closed-p (only-client display)))))))
        (ffi:close-fd fd)))))

(deftest a-new-id-already-in-use-is-a-protocol-error
  (with-demo (display)
    (let ((fd (raw-connect display)))
      (unwind-protect
           (progn
             (send-message fd 1 1 (lambda (buffer) (wire:put-new-id buffer 2)))
             (run-server display)
             (read-events fd)                     ; the two global announcements
             (send-message fd 1 1 (lambda (buffer) (wire:put-new-id buffer 2)))
             (run-server display)
             (destructuring-bind (object-id code message) (error-reply (read-events fd))
               (ok (= 1 object-id))
               (ok (= srv:+error-invalid-object+ code))
               (ok (search "already in use" message)))
             (ok (null (srv:display-clients display))))
        (ffi:close-fd fd)))))

(deftest a-new-id-outside-the-client-range-is-refused
  (with-demo (display)
    (let ((fd (raw-connect display)))
      (unwind-protect
           (progn
             (send-message fd 1 1 (lambda (buffer) (wire:put-new-id buffer #xFF000001)))
             (run-server display)
             (destructuring-bind (object-id code message) (error-reply (read-events fd))
               (ok (= 1 object-id))
               (ok (= srv:+error-invalid-object+ code))
               (ok (search "client range" message)))
             (ok (null (srv:display-clients display))))
        (ffi:close-fd fd)))))

;;; ---------------------------------------------------------------------------
;;; Dispatch failures
;;; ---------------------------------------------------------------------------

(deftest an-unknown-object-id-is-invalid-object
  (with-demo (display)
    (let ((fd (raw-connect display)))
      (unwind-protect
           (progn
             (send-message fd 77 0 nil)
             (run-server display)
             (destructuring-bind (object-id code message) (error-reply (read-events fd))
               (ok (= 77 object-id) "the error names the object the client used")
               (ok (= srv:+error-invalid-object+ code))
               (ok (search "no object with id 77" message)))
             (ok (null (srv:display-clients display))))
        (ffi:close-fd fd)))))

(deftest an-unknown-opcode-is-invalid-method
  (with-demo (display)
    (let ((fd (raw-connect display)))
      (unwind-protect
           (progn
             (send-message fd 1 9 nil)
             (run-server display)
             (destructuring-bind (object-id code message) (error-reply (read-events fd))
               (declare (ignore object-id))
               (ok (= srv:+error-invalid-method+ code))
               (ok (search "no request with opcode 9" message)))
             (ok (null (srv:display-clients display))))
        (ffi:close-fd fd)))))

(deftest a-request-above-the-resource-version-is-invalid-method
  (with-demo (display)
    (let ((fd (raw-connect display)))
      (unwind-protect
           (progn
             ;; get_registry is opcode 1 on wl_display; the registry is id 2.
             (send-message fd 1 1 (lambda (buffer) (wire:put-new-id buffer 2)))
             (run-server display)
             (read-events fd)                     ; the two global announcements
             ;; Bind wl_output at version 1 as id 3.
             (send-message fd 2 0
                           (lambda (buffer)
                             (wire:put-uint buffer 2)
                             (wire:put-string buffer "wl_output")
                             (wire:put-uint buffer 1)
                             (wire:put-new-id buffer 3)))
             (run-server display)
             (read-events fd)                     ; geometry and mode
             ;; wl_output.release is opcode 0 and exists only from version 3.
             (send-message fd 3 0 nil)
             (run-server display)
             (destructuring-bind (object-id code message) (error-reply (read-events fd))
               (ok (= 3 object-id))
               (ok (= srv:+error-invalid-method+ code))
               (ok (search "needs version" message)))
             (ok (null (srv:display-clients display))))
        (ffi:close-fd fd)))))

(deftest an-unimplemented-request-is-an-implementation-error
  (with-demo (display)
    (let ((fd (raw-connect display)))
      (unwind-protect
           (progn
             (send-message fd 1 1 (lambda (buffer) (wire:put-new-id buffer 2)))
             (run-server display)
             (read-events fd)
             ;; Bind wl_compositor (global 1) as id 3, then call create_surface
             ;; (opcode 0, one new_id): phase 1 has no surfaces.
             (send-message fd 2 0
                           (lambda (buffer)
                             (wire:put-uint buffer 1)
                             (wire:put-string buffer "wl_compositor")
                             (wire:put-uint buffer 1)
                             (wire:put-new-id buffer 3)))
             (run-server display)
             (send-message fd 3 0 (lambda (buffer) (wire:put-new-id buffer 4)))
             (run-server display)
             (destructuring-bind (object-id code message) (error-reply (read-events fd))
               (ok (= 3 object-id))
               (ok (= srv:+error-implementation+ code))
               (ok (search "not implemented" message)))
             (ok (null (srv:display-clients display))))
        (ffi:close-fd fd)))))

(deftest a-destructor-request-frees-the-id
  (with-demo (display)
    (let ((fd (raw-connect display)))
      (unwind-protect
           (progn
             (send-message fd 1 1 (lambda (buffer) (wire:put-new-id buffer 2)))
             (run-server display)
             (read-events fd)
             ;; Bind wl_output at version 3 as id 3, then release it.
             (send-message fd 2 0
                           (lambda (buffer)
                             (wire:put-uint buffer 2)
                             (wire:put-string buffer "wl_output")
                             (wire:put-uint buffer 3)
                             (wire:put-new-id buffer 3)))
             (run-server display)
             (read-events fd)                     ; geometry, mode, scale, done
             (send-message fd 3 0 nil)            ; wl_output.release
             (run-server display)
             (let ((events (read-events fd)))
               (ok (= 1 (length events)))
               (destructuring-bind (object-id opcode reader) (first events)
                 (ok (= 1 object-id) "wl_display.delete_id")
                 (ok (= 1 opcode))
                 (ok (= 3 (wire:read-uint reader)))))
             ;; The id is free again, so the client may bind at it once more.
             (send-message fd 2 0
                           (lambda (buffer)
                             (wire:put-uint buffer 2)
                             (wire:put-string buffer "wl_output")
                             (wire:put-uint buffer 1)
                             (wire:put-new-id buffer 3)))
             (run-server display)
             (ok (= 2 (length (read-events fd)))
                 "the rebound output sends geometry and mode, and nothing newer")
             (ok (not (srv:client-closed-p (only-client display)))))
        (ffi:close-fd fd)))))

;;; ---------------------------------------------------------------------------
;;; Teardown and hygiene
;;; ---------------------------------------------------------------------------

(deftest peer-eof-tears-the-client-down
  (with-demo (display)
    (let ((fd (raw-connect display)))
      (send-message fd 1 1 (lambda (buffer) (wire:put-new-id buffer 2)))
      (run-server display)
      (ok (= 1 (length (srv:display-clients display))))
      (ffi:close-fd fd)
      (run-server display)
      (ok (null (srv:display-clients display))
          "a client that goes away is removed without an error"))))

(deftest a-half-written-message-is-not-an-error
  ;; Four octets and then silence: the server keeps the tail and waits.
  (with-demo (display)
    (let ((fd (raw-connect display)))
      (unwind-protect
           (progn
             (cffi:with-foreign-string (pointer "abcd")
               (ffi:write-from-pointer fd pointer 4))
             (run-server display)
             (ok (= 1 (length (srv:display-clients display)))
                 "a partial header is buffered, not rejected")
             (ok (= 4 (io:input-buffer-pending-octets
                       (srv:client-input (only-client display)))))
             (ok (not (srv:client-closed-p (only-client display)))))
        (ffi:close-fd fd)))))

(deftest connect-disconnect-cycles-leak-nothing
  (with-demo (display)
    (let ((before (fd-count)))
      (loop repeat 50
            do (let ((fd (ffi:connect-unix-socket (srv:display-socket-path display))))
          (send-message fd 1 1 (lambda (buffer) (wire:put-new-id buffer 2)))
          (run-server display :cycles 2)
          (ffi:close-fd fd)
          (run-server display :cycles 2)))
      (ok (null (srv:display-clients display)))
      (ok (= before (fd-count))
          (format nil "descriptors before ~D, after ~D" before (fd-count))))))

(deftest a-client-that-never-reads-is-backpressured
  (with-demo (display)
    (let ((fd (raw-connect display)))
      (unwind-protect
           (let ((client (only-client display)))
             ;; Queue far more than a socket buffer, then flush once: the write
             ;; stops at EAGAIN and the interest must drop to write-only, so the
             ;; server stops reading requests from a client that is not listening.
             (loop repeat 2000
                   do (let ((buffer (srv:client-output client)))
                 (let ((start (wire:begin-message buffer 1 1)))
                   (wire:put-string buffer (make-string 500 :initial-element #\x))
                   (wire:end-message buffer start))))
             (srv:flush-client client)
             (ok (srv:client-congested-p client))
             (ok (eq :write (reactor:source-interest (srv::client-source client)))
                 "a congested client is not read from")
             ;; Drain it and flush again: reading is re-enabled.
             (let ((octets (make-array 65536 :element-type '(unsigned-byte 8))))
               (loop repeat 10000
                     do (let ((read (nth-value 0 (ffi:read-into fd octets 0 65536))))
                          (srv:flush-client client)
                          (when (and (zerop read)
                                     (zerop (wire:buffer-size (srv:client-output client))))
                            (return)))))
             (ok (not (srv:client-congested-p client)))
             (ok (eq :read (reactor:source-interest (srv::client-source client)))))
        (ffi:close-fd fd)))))

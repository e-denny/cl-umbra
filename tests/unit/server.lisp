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
  (ok (= 1 (length events)) (format nil "exactly one reply expected, got ~D" (length events)))
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

;;; ---------------------------------------------------------------------------
;;; wl_shm: pools, buffers, and the numbers a client could otherwise abuse
;;; ---------------------------------------------------------------------------

(defmacro with-shm-display ((display) &body body)
  "A display offering wl_shm as well as the socket, for the pixel tests."
  `(with-display (,display)
     (srv:add-global ,display
                     :interface "wl_shm"
                     :version 1
                     :resource-class 'srv:shm
                     :bind #'srv:send-shm-formats)
     (locally ,@body)))

(defun send-bind (socket registry-id name interface version new-id)
  (send-message socket registry-id 0
                (lambda (buffer)
                  (wire:put-uint buffer name)
                  (wire:put-string buffer interface)
                  (wire:put-uint buffer version)
                  (wire:put-new-id buffer new-id))))

(defun send-get-registry (socket registry-id)
  (send-message socket 1 1 (lambda (buffer) (wire:put-new-id buffer registry-id))))

(defun bind-shm (display socket)
  "get_registry then bind the wl_shm global as object 3; returns the socket."
  (send-get-registry socket 2)
  (run-server display)
  (read-events socket)                          ; the global announcement
  (send-bind socket 2 1 "wl_shm" 1 3)
  (run-server display)
  (read-events socket)                          ; the two format events
  socket)

(defun send-create-pool (socket pool-id fd size &key (shm-id 3))
  (let ((buffer (wire:make-message-buffer)))
    (let ((start (wire:begin-message buffer shm-id 0)))
      (wire:put-new-id buffer pool-id)
      (wire:put-fd buffer fd)
      (wire:put-int buffer size)
      (wire:end-message buffer start))
    (io:flush-buffer socket buffer)))

(defun send-create-buffer (socket pool-id buffer-id offset width height stride format)
  (send-message socket pool-id 0
                (lambda (buffer)
                  (wire:put-new-id buffer buffer-id)
                  (wire:put-int buffer offset)
                  (wire:put-int buffer width)
                  (wire:put-int buffer height)
                  (wire:put-int buffer stride)
                  (wire:put-uint buffer format))))

(defun make-pixels (width height colour)
  "An image of solid COLOUR, as the client would have written it: ARGB8888."
  (let* ((stride (* width 4))
         (octets (make-array (* stride height) :element-type '(unsigned-byte 8))))
    (dotimes (row height octets)
      (dotimes (column width)
        (let ((offset (+ (* row stride) (* column 4))))
          (setf (aref octets offset) (ldb (byte 8 0) colour)
                (aref octets (+ offset 1)) (ldb (byte 8 8) colour)
                (aref octets (+ offset 2)) (ldb (byte 8 16) colour)
                (aref octets (+ offset 3)) (ldb (byte 8 24) colour)))))))

(defun make-client-pool (width height colour)
  "A memfd holding a solid image; returns (values fd size)."
  (let* ((stride (* width 4))
         (size (* stride height))
         (fd (ffi:memfd-create "cl-wayland-shm-test")))
    (ffi:set-file-size fd size)
    (let ((mapping (ffi:map-file fd size
                                 :protection (logior ffi:+prot-read+ ffi:+prot-write+))))
      (unwind-protect
           (ffi:write-mapped-octets mapping 0 (make-pixels width height colour))
        (ffi:unmap-file mapping size)))
    (values fd size)))

(deftest bind-shm-advertises-argb-and-xrgb
  (with-shm-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (send-get-registry socket 2)
             (run-server display)
             (read-events socket)
             (send-bind socket 2 1 "wl_shm" 1 3)
             (run-server display)
             (let ((events (read-events socket)))
               (ok (= 2 (length events)))
               (destructuring-bind ((id1 op1 reader1) (id2 op2 reader2)) events
                 (ok (= 3 id1))
                 (ok (= 0 op1) "wl_shm.format is opcode 0")
                 (ok (= srv:+wl-shm-format-argb8888+ (wire:read-uint reader1)))
                 (ok (= 3 id2))
                 (ok (= srv:+wl-shm-format-xrgb8888+ (wire:read-uint reader2))))))
        (ffi:close-fd socket)))))

(deftest a-pool-is-mapped-and-a-buffer-points-into-it
  (with-shm-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-shm display socket)
             (multiple-value-bind (fd size) (make-client-pool 8 4 #xFFFF0000)
               (send-create-pool socket 4 fd size)
               (run-server display)
               (ok (null (read-events socket)) "creating a pool answers nothing")
               (send-create-buffer socket 4 5 0 8 4 32 srv:+wl-shm-format-argb8888+)
               (run-server display)
               (ok (null (read-events socket)) "creating a buffer answers nothing")
               (let* ((client (only-client display))
                      (pool (wayland.object:object-table-ref (srv:client-objects client) 4))
                      (buffer (wayland.object:object-table-ref (srv:client-objects client) 5)))
                 (ok (= 5 (wayland.object:object-table-count (srv:client-objects client)))
                     "display, registry, shm, pool and buffer")
                 (ok (typep pool 'srv:shm-pool))
                 (ok (= size (srv:shm-pool-size pool)))
                 (ok (not (cffi:null-pointer-p (srv:shm-pool-mapping pool))))
                 (ok (typep buffer 'srv:shm-buffer))
                 (ok (eq pool (srv:shm-buffer-pool buffer)))
                 (ok (= 8 (srv:shm-buffer-width buffer)))
                 (ok (= 4 (srv:shm-buffer-height buffer)))
                 (ok (= 32 (srv:shm-buffer-stride buffer)))
                 (ok (= 128 (srv:shm-buffer-byte-length buffer)))
                 (let ((pixels (ffi:mapped-octets (srv:shm-buffer-pointer buffer) 0 4)))
                   (ok (equalp #(0 0 255 255) pixels)
                       "ARGB8888 little-endian: B, G, R, A"))))
        (ffi:close-fd socket))))))

(defun shm-attempt (display width height stride offset format &key (pool-size 128))
  "Create a pool and an (often invalid) buffer; return the error code, or NIL.

A top-level helper rather than a local one: the assertions read better without a
nested flet, and the unwind-protect is easier to get right in one place."
  (let ((socket (raw-connect display)))
    (unwind-protect
         (progn
           (bind-shm display socket)
           (multiple-value-bind (fd size) (make-client-pool 8 4 #xFF00FF00)
             (declare (ignore size))
             (send-create-pool socket 4 fd pool-size)
             (run-server display)
             (send-create-buffer socket 4 5 offset width height stride format)
             (run-server display)
             (let ((reply (read-events socket)))
               (unless reply
                 (error "no reply for width ~D height ~D stride ~D offset ~D format ~D pool ~D"
                        width height stride offset format pool-size))
               (destructuring-bind (object-id code message) (error-reply reply)
                 (declare (ignore object-id message))
                 code))))
      (ffi:close-fd socket))))

(deftest buffer-validation-rejects-what-could-read-our-memory
  (with-shm-display (display)
    (flet ((rejected (code what)
             (ok (eql code srv:+wl-shm-pool-error-invalid-stride+) what)))
      (rejected (shm-attempt display 8 4 16 0 srv:+wl-shm-format-argb8888+)
                "stride below width * 4")
      (rejected (shm-attempt display 8 4 34 0 srv:+wl-shm-format-argb8888+)
                "stride not a multiple of 4")
      (rejected (shm-attempt display 8 4 32 2 srv:+wl-shm-format-argb8888+)
                "offset not a multiple of 4")
      (rejected (shm-attempt display 8 4 32 0 srv:+wl-shm-format-argb8888+ :pool-size 100)
                "buffer reaches past the end of the pool")
      (rejected (shm-attempt display 8 4 32 0 srv:+wl-shm-format-argb8888+ :pool-size 127)
                "off by one at the end of the pool")
      (rejected (shm-attempt display 0 4 32 0 srv:+wl-shm-format-argb8888+)
                "zero width"))
    (ok (eql (shm-attempt display 8 4 32 0 99)
             srv:+wl-shm-pool-error-invalid-format+)
        "an unadvertised format")))

(deftest an-oversized-pool-is-refused-and-its-descriptor-closed
  (with-shm-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-shm display socket)
             ;; Measured before the test's own memfd exists, and with the server
             ;; having accepted the client: after the refusal the accepted
             ;; descriptor is gone and the memfd remains, so an equal count means
             ;; the *received* copy was closed too.
             (let ((before (fd-count)))
               (multiple-value-bind (fd size) (make-client-pool 8 4 #xFF0000FF)
                 (declare (ignore size))
                 (unwind-protect
                      (progn
                        (send-create-pool socket 4 fd 0)        ; size 0: refused
                        (run-server display)
                        (destructuring-bind (object-id code message)
                            (error-reply (read-events socket))
                          (ok (= 3 object-id) "the error names the wl_shm object")
                          (ok (eql code srv:+wl-shm-error-invalid-fd+))
                          (ok (search "pool size" message)))
                        (ok (null (srv:display-clients display))
                            "the client is disconnected")
                        (ok (= before (fd-count))
                            (format nil
                                    "the received descriptor was closed, not leaked (~D -> ~D)"
                                    before (fd-count))))
                   (ffi:close-fd fd)))))
        (ffi:close-fd socket)))))

(deftest a-pool-outlives-its-object-while-a-buffer-uses-it
  ;; wl_shm's own words: "a buffer will keep a reference to the pool it was
  ;; created from so it is valid to destroy the pool immediately after creating a
  ;; buffer from it".  So the mapping belongs to the buffer, and the pool's
  ;; descriptor is closed as soon as the pool object is gone.
  (with-shm-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-shm display socket)
             (multiple-value-bind (fd size) (make-client-pool 8 4 #xFF00FF00)
               (send-create-pool socket 4 fd size)
               (run-server display)
               (send-create-buffer socket 4 5 0 8 4 32 srv:+wl-shm-format-argb8888+)
               (run-server display)
               (let* ((client (only-client display))
                      (pool (wayland.object:object-table-ref (srv:client-objects client) 4))
                      (buffer (wayland.object:object-table-ref (srv:client-objects client) 5)))
                 (send-message socket 4 1 nil)        ; wl_shm_pool.destroy
                 (run-server display)
                 (ok (srv:resource-destroyed-p pool) "the pool object is gone")
                 (ok (= -1 (srv:shm-pool-fd pool)) "its descriptor is closed")
                 (ok (not (cffi:null-pointer-p (srv:shm-pool-mapping pool)))
                     "the pixels stay mapped while a buffer uses them")
                 (ok (not (srv:resource-destroyed-p buffer))
                     "the buffer is alive")
                 (let ((events (read-events socket)))
                   (ok (= 1 (length events)) "one delete_id, for the pool")
                   (ok (= 4 (wire:read-uint (third (first events))))))
                 ;; Now the buffer goes: the last reference, so the mapping does.
                 (send-message socket 5 0 nil)        ; wl_buffer.destroy
                 (run-server display)
                 (ok (null (srv:shm-pool-mapping pool)) "the mapping is gone")
                 (ok (srv:resource-destroyed-p buffer))
                 (let ((events (read-events socket)))
                   (ok (= 1 (length events)) "and one more delete_id, for the buffer"))))
        (ffi:close-fd socket))))))

(deftest destroying-a-pool-with-no-buffers-unmaps-at-once
  (with-shm-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-shm display socket)
             (multiple-value-bind (fd size) (make-client-pool 8 4 #xFF00FF00)
               (send-create-pool socket 4 fd size)
               (run-server display)
               (let* ((client (only-client display))
                      (pool (wayland.object:object-table-ref (srv:client-objects client) 4)))
                 (send-message socket 4 1 nil)
                 (run-server display)
                 (ok (null (srv:shm-pool-mapping pool)))
                 (ok (= -1 (srv:shm-pool-fd pool))))))
        (ffi:close-fd socket)))))

(deftest a-client-that-disappears-leaves-no-mapping-or-descriptor
  ;; The descriptor count is only meaningful if the test holds nothing of its
  ;; own: the memfd is closed as soon as the server has its duplicate, so what is
  ;; compared before and after is the *server's* copy and the accepted socket.
  (with-shm-display (display)
    (let ((before (fd-count))
          (socket nil))
      (unwind-protect
           (progn
             (setf socket (raw-connect display))
             (bind-shm display socket)
             (multiple-value-bind (fd size) (make-client-pool 8 4 #xFF0000FF)
               (send-create-pool socket 4 fd size)
               (run-server display)
               (ffi:close-fd fd))
             (let* ((client (only-client display))
                    (pool (wayland.object:object-table-ref (srv:client-objects client) 4)))
               (ffi:close-fd socket)
               (setf socket nil)
               (run-server display)
               (ok (null (srv:display-clients display)))
               (ok (null (srv:shm-pool-mapping pool)))
               (ok (= -1 (srv:shm-pool-fd pool)))))
        (when socket (ffi:close-fd socket)))
      (ok (= before (fd-count))
          (format nil "descriptors before ~D, after ~D" before (fd-count))))))

;;; ---------------------------------------------------------------------------
;;; xdg-shell: the toplevel handshake
;;;
;;; Raw messages again, for the same reason as the shm tests: only a client that
;;; can make the *wrong* request can prove that we refuse it.  Opcodes used here
;;; are the schema's: wl_compositor.create_surface 0, xdg_wm_base.get_xdg_surface
;;; 2, .create_positioner 1, .destroy 0, .pong 3, xdg_surface.get_toplevel 1,
;;; .ack_configure 4, .destroy 0, wl_surface.destroy 0, .attach 1, .damage 2,
;;; .frame 3, .commit 6, xdg_toplevel.set_title 2, .set_app_id 3.
;;; ---------------------------------------------------------------------------

(defmacro with-xdg-display ((display) &body body)
  "A display offering wl_shm (global 1), wl_compositor (2) and xdg_wm_base (3)."
  `(with-display (,display)
     (srv:add-global ,display
                     :interface "wl_shm"
                     :version 1
                     :resource-class 'srv:shm
                     :bind #'srv:send-shm-formats)
     (srv:add-global ,display
                     :interface "wl_compositor"
                     :version 1
                     :resource-class 'srv:compositor)
     (srv:add-global ,display
                     :interface "xdg_wm_base"
                     :version 1
                     :resource-class 'srv:xdg-wm-base)
     (locally ,@body)))

(defun bind-xdg (display socket)
  "get_registry (2), then bind wl_shm as 5, wl_compositor as 3, xdg_wm_base as 4."
  (send-get-registry socket 2)
  (run-server display)
  (read-events socket)                          ; the three global announcements
  (send-bind socket 2 1 "wl_shm" 1 5)
  (send-bind socket 2 2 "wl_compositor" 1 3)
  (send-bind socket 2 3 "xdg_wm_base" 1 4)
  (run-server display)
  (read-events socket)                          ; the two shm formats
  socket)

(defun server-object (display id)
  "The resource the server holds for the client-chosen object id ID."
  (wayland.object:object-table-ref (srv:client-objects (only-client display)) id))

(defun make-toplevel (display socket)
  "create_surface (10), get_xdg_surface (11), get_toplevel (12); nothing committed."
  (send-message socket 3 0 (lambda (buffer) (wire:put-new-id buffer 10)))
  (send-message socket 4 2 (lambda (buffer)
                             (wire:put-new-id buffer 11)
                             (wire:put-object buffer 10)))
  (send-message socket 11 1 (lambda (buffer) (wire:put-new-id buffer 12)))
  (run-server display))

(defun commit-surface (display socket &optional (surface-id 10))
  "wl_surface.commit, then give the server the cycle it needs to answer it."
  (send-message socket surface-id 6 nil)
  (run-server display))

(defun ack-configure (socket serial &optional (shell-id 11))
  (send-message socket shell-id 4 (lambda (buffer) (wire:put-uint buffer serial))))

(defun attach-buffer (socket buffer-id &optional (surface-id 10))
  "wl_surface.attach is opcode 1: opcode 0 is destroy, which is how this test
first proved that opcodes are worth looking up rather than assuming."
  (send-message socket surface-id 1
                (lambda (buffer)
                  (wire:put-object buffer buffer-id)
                  (wire:put-int buffer 0)
                  (wire:put-int buffer 0))))

(defun make-buffer-on-the-shm-global (display socket &key (pool-id 20) (buffer-id 21))
  "A real 8x4 ARGB8888 buffer; the wl_shm global is object 5 (see BIND-XDG)."
  (multiple-value-bind (fd size) (make-client-pool 8 4 #xFF00FF00)
    (send-create-pool socket pool-id fd size :shm-id 5)
    (run-server display)
    (send-create-buffer socket pool-id buffer-id 0 8 4 32
                        srv:+wl-shm-format-argb8888+)
    (run-server display)))

(defun read-configure (socket)
  "Decode an initial configure pair; returns (values width height states serial)."
  (let ((events (read-events socket)))
    (ok (= 2 (length events))
        (format nil "a toplevel configure and a surface configure, got ~D message~:P"
                (length events)))
    (destructuring-bind ((toplevel-id toplevel-opcode toplevel-reader)
                         (shell-id shell-opcode shell-reader))
        events
      (ok (= 12 toplevel-id) "xdg_toplevel.configure arrives on the toplevel")
      (ok (= 0 toplevel-opcode) "xdg_toplevel.configure is opcode 0")
      (ok (= 11 shell-id) "xdg_surface.configure arrives on the xdg_surface")
      (ok (= 0 shell-opcode) "xdg_surface.configure is opcode 0")
      (let ((width (wire:read-int toplevel-reader))
            (height (wire:read-int toplevel-reader))
            (states (wire:read-array toplevel-reader)))
        (values width height states (wire:read-uint shell-reader))))))

(deftest the-initial-commit-is-answered-with-a-zero-by-zero-configure
  (with-xdg-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-xdg display socket)
             (make-toplevel display socket)
             (send-message socket 12 2 (lambda (buffer) (wire:put-string buffer "hello")))
             (send-message socket 12 3 (lambda (buffer)
                                         (wire:put-string buffer "org.example.test")))
             (commit-surface display socket)
             (multiple-value-bind (width height states serial) (read-configure socket)
               (ok (= 0 width) "0x0 means: you choose (docs/protocol-layer.md §8)")
               (ok (= 0 height))
               (ok (null states) "the state array is empty, not absent")
               (let* ((shell (server-object display 11))
                      (toplevel (server-object display 12))
                      (surface (srv:xdg-surface-surface shell)))
                 (ok (eq surface (server-object display 10))
                     "the xdg_surface points at the wl_surface it was made for")
                 (ok (srv:xdg-surface-configured-p shell) "a configure was sent")
                 (ok (not (srv:xdg-surface-acknowledged-p shell))
                     "but not yet acknowledged")
                 (ok (equal (list serial) (srv:xdg-surface-pending-serials shell))
                     "the serial is kept for the ack to match")
                 (ok (equal "hello" (srv:xdg-toplevel-title toplevel)))
                 (ok (equal "org.example.test" (srv:xdg-toplevel-app-id toplevel)))
                 (ok (not (srv:surface-mapped-p surface))
                     "a configure does not map anything by itself"))
               (ack-configure socket serial)
               (run-server display)
               (let ((shell (server-object display 11)))
                 (ok (srv:xdg-surface-acknowledged-p shell))
                 (ok (= 1 (srv:xdg-surface-ack-count shell)))
                 (ok (null (srv:xdg-surface-pending-serials shell))
                     "acking consumes the serial"))))
        (ffi:close-fd socket)))))

(deftest a-buffer-attached-before-the-first-ack-is-refused
  (with-xdg-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-xdg display socket)
             (make-toplevel display socket)
             (commit-surface display socket)
             (read-configure socket)                     ; received, not acked
             (make-buffer-on-the-shm-global display socket)
             (attach-buffer socket 21)
             (commit-surface display socket)
             (run-server display)
             (destructuring-bind (object-id code message)
                 (error-reply (read-events socket))
               (ok (= 11 object-id) "the error names the xdg_surface")
               (ok (= 3 code) "xdg_surface.error.unconfigured_buffer")
               (ok (search "before the initial configure" message)))
             (ok (null (srv:display-clients display)) "the client is disconnected"))
        (ffi:close-fd socket)))))

(deftest an-ack-for-a-serial-we-never-sent-is-refused
  (with-xdg-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-xdg display socket)
             (make-toplevel display socket)
             (commit-surface display socket)
             (multiple-value-bind (width height states serial) (read-configure socket)
               (declare (ignore width height states))
               (ack-configure socket (+ serial 1000))
               (run-server display)
               (destructuring-bind (object-id code message)
                   (error-reply (read-events socket))
                 (ok (= 11 object-id))
                 (ok (= 4 code) "xdg_surface.error.invalid_serial")
                 (ok (search "never sent" message)))))
        (ffi:close-fd socket)))))

(deftest a-second-role-or-a-second-xdg-surface-is-refused
  (with-xdg-display (display)
    ;; One wl_surface, two roles.
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-xdg display socket)
             (make-toplevel display socket)
             (send-message socket 11 1 (lambda (buffer) (wire:put-new-id buffer 13)))
             (run-server display)
             (destructuring-bind (object-id code message)
                 (error-reply (read-events socket))
               (ok (= 11 object-id))
               (ok (= 2 code) "xdg_surface.error.already_constructed")
               (ok (search "already has the toplevel role" message))))
        (ffi:close-fd socket)))
    ;; One wl_surface, two xdg_surfaces.
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-xdg display socket)
             (make-toplevel display socket)
             (send-message socket 4 2 (lambda (buffer)
                                        (wire:put-new-id buffer 14)
                                        (wire:put-object buffer 10)))
             (run-server display)
             (destructuring-bind (object-id code message)
                 (error-reply (read-events socket))
               (ok (= 4 object-id) "this one is xdg_wm_base's error")
               (ok (= 0 code) "xdg_wm_base.error.role")
               (ok (search "already has the toplevel role" message))))
        (ffi:close-fd socket)))))

(deftest role-destruction-order-is-enforced
  (with-xdg-display (display)
    ;; An xdg_surface may not outlive the role it created.
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-xdg display socket)
             (make-toplevel display socket)
             (send-message socket 11 0 nil)                ; xdg_surface.destroy
             (run-server display)
             (destructuring-bind (object-id code message)
                 (error-reply (read-events socket))
               (ok (= 11 object-id))
               (ok (= 6 code) "xdg_surface.error.defunct_role_object")
               (ok (search "outlives" message))))
        (ffi:close-fd socket)))
    ;; And xdg_wm_base may not outlive its surfaces.
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-xdg display socket)
             (make-toplevel display socket)
             (send-message socket 4 0 nil)                 ; xdg_wm_base.destroy
             (run-server display)
             (destructuring-bind (object-id code message)
                 (error-reply (read-events socket))
               (ok (= 4 object-id))
               (ok (= 1 code) "xdg_wm_base.error.defunct_surfaces")
               (ok (search "still alive" message))))
        (ffi:close-fd socket)))))

(deftest an-unimplemented-request-is-an-implementation-error
  (with-xdg-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-xdg display socket)
             (send-message socket 4 1 (lambda (buffer) (wire:put-new-id buffer 15)))
             (run-server display)
             (destructuring-bind (object-id code message)
                 (error-reply (read-events socket))
               (ok (= 4 object-id))
               (ok (= 3 code) "wl_display.error.implementation: not built yet")
               (ok (search "not implemented" message)
                   "an unsupported request says so instead of pretending"))
             (ok (null (srv:display-clients display))))
        (ffi:close-fd socket)))))

(deftest a-toplevel-maps-unmaps-and-gets-its-buffer-back
  (with-xdg-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-xdg display socket)
             (make-toplevel display socket)
             (commit-surface display socket)
             (multiple-value-bind (width height states serial) (read-configure socket)
               (declare (ignore width height states))
               (ack-configure socket serial))
             (make-buffer-on-the-shm-global display socket)
             ;; The frame callback is asked for in the same commit as the buffer;
             ;; it must not fire until the frame is presented.
             (send-message socket 10 3 (lambda (buffer) (wire:put-new-id buffer 22)))
             (attach-buffer socket 21)
             (send-message socket 10 2 (lambda (buffer)
                                         (wire:put-int buffer 0)
                                         (wire:put-int buffer 0)
                                         (wire:put-int buffer 8)
                                         (wire:put-int buffer 4)))
             (commit-surface display socket)
             (run-server display)
             (let* ((shell (server-object display 11))
                    (toplevel (server-object display 12))
                    (surface (srv:xdg-surface-surface shell))
                    (buffer (server-object display 21)))
               (ok (srv:surface-mapped-p surface) "a committed buffer maps the surface")
               (ok (srv:xdg-surface-mapped-p shell))
               (ok (srv:xdg-toplevel-mapped-p toplevel))
               (ok (eq buffer (srv:surface-current-buffer surface)))
               (ok (not (srv:shm-buffer-released-p buffer))
                   "an attached buffer belongs to the compositor")
               (let ((events (read-events socket :timeout 0.05)))
                 (ok (notany (lambda (event) (= 22 (first event))) events)
                     "the frame callback waits for presentation"))
               ;; Presentation is the compositor's job; do what a render does.
               ;; Nothing dispatched, so nothing flushed: flush by hand.
               (srv:fire-frame-callbacks surface)
               (srv:flush-all display)
               (let* ((events (read-events socket))
                      (done (find-if (lambda (event) (= 22 (first event))) events)))
                 (ok done "wl_callback.done arrives once the frame is presented")
                 (when done
                   (ok (= 0 (second done)))
                   (ok (integerp (wire:read-uint (third done)))
                       "done carries a msec timestamp")))
               ;; attach(nil) unmaps, and the replaced buffer goes back to the client.
               (attach-buffer socket nil)
               (commit-surface display socket)
               (run-server display)
               (ok (not (srv:surface-mapped-p surface)) "attach(nil) unmaps")
               (ok (not (srv:xdg-toplevel-mapped-p toplevel)))
               (let ((events (read-events socket)))
                 (ok (find-if (lambda (event) (= 21 (first event))) events)
                     "the unmapped buffer is released")
                 (ok (srv:shm-buffer-released-p buffer)))))
        (ffi:close-fd socket)))))

(deftest a-ping-is-answered-with-its-own-serial
  (with-xdg-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-xdg display socket)
             (let* ((wm-base (server-object display 4))
                    (serial (srv:ping-xdg-wm-base wm-base)))
               ;; The event is queued in our output buffer, not on the socket
               ;; yet: nothing was dispatched, so no cycle flushed it.
               (srv:flush-all display)
               (destructuring-bind (object-id opcode reader) (first (read-events socket))
                 (ok (= 4 object-id))
                 (ok (= 0 opcode) "xdg_wm_base.ping is opcode 0")
                 (ok (= serial (wire:read-uint reader))
                     "the ping carries the serial the pong must repeat"))
               (send-message socket 4 3 (lambda (buffer) (wire:put-uint buffer serial)))
               (run-server display)
               (ok (null (srv:xdg-wm-base-pending-pings wm-base)))
               (ok (= 1 (srv:xdg-wm-base-pong-count wm-base)))))
        (ffi:close-fd socket)))))
;;; ---------------------------------------------------------------------------
;;; wl_seat, wl_pointer, wl_keyboard: the input protocol, and the descriptors it
;;; carries
;;;
;;; Same raw peer as everywhere else.  Opcodes: wl_seat.get_pointer 0,
;;; .get_keyboard 1, .get_touch 2, .release 3; wl_pointer.set_cursor 0;
;;; wl_region.add 1, .subtract 2; wl_shm_pool.resize 3; wl_compositor.create_region
;;; 1.  Events: wl_pointer.enter 0, .leave 1, .motion 2, .button 3, .axis 4;
;;; wl_keyboard.keymap 0, .enter 1, .leave 2, .key 3, .modifiers 4, .repeat_info 5;
;;; wl_seat.capabilities 0, .name 1.
;;;
;;; The keymap the tests hand the seat is a literal, not cf.input's: this is a
;;; wire test, and what matters is that the octets and the descriptor arrive, not
;;; that the generator is good (the seat gate checks that with libxkbcommon).
;;; ---------------------------------------------------------------------------

(defparameter *test-keymap*
  "xkb_keymap { xkb_keycodes \"t\" { minimum = 8; maximum = 255; <ESC> = 9; }; xkb_symbols \"t\" { key <ESC> { [ Escape ] }; }; };"
  "A minimal keymap, sent verbatim so the test can compare octets.")

(defmacro with-seat-display ((display &key (capabilities 3)) &body body)
  "A display offering wl_shm (global 1), wl_compositor (2) and wl_seat (3)."
  `(with-display (,display)
     (srv:add-global ,display
                     :interface "wl_shm"
                     :version 1
                     :resource-class 'srv:shm
                     :bind #'srv:send-shm-formats)
     (srv:add-global ,display
                     :interface "wl_compositor"
                     :version 1
                     :resource-class 'srv:compositor)
     (let ((seat (srv:make-seat ,display :name "seat0"
                                         :capabilities ,capabilities)))
       (srv:add-seat-global ,display seat)
       (srv:set-seat-keymap seat *test-keymap* :repeat-rate 25 :repeat-delay 600)
       (locally ,@body))))

(defun seat-of (display)
  "The SEAT the test display offers (the global's data, found by interface)."
  (srv:global-data
   (find "wl_seat" (srv:display-globals display)
         :key #'srv:global-interface :test #'string=)))

(defun bind-seat (display socket &key (version 4) (id 4))
  "get_registry (2) and bind wl_seat as ID; returns the seat resource."
  (send-get-registry socket 2)
  (run-server display)
  (read-events socket)
  (send-bind socket 2 3 "wl_seat" version id)
  (run-server display)
  (read-events socket)                          ; name and capabilities
  (server-object display id))

(defun receive-octets/keep-fds (fd &key (size 8192))
  "RECEIVE-OCTETS, but handing back the descriptors instead of closing them."
  (let ((octets (make-array size :element-type '(unsigned-byte 8))))
    (multiple-value-bind (count fds truncated-p eof-p)
        (ffi:receive-with-ancillary fd octets 0 size :fds-max 8)
      (ok (not truncated-p) "no descriptor truncation expected here")
      (values (subseq octets 0 count) fds eof-p))))

(defun read-events-and-fds (fd &key (timeout 0.5))
  "READ-EVENTS, plus the descriptors that arrived (in order, not closed).

Descriptors are attached to writes, not to messages, so the caller is told what
arrived and which messages came with it; for one message carrying one keymap that
is exactly enough."
  (let ((deadline (+ (reactor:monotonic-now) timeout))
        (fds '()))
    (loop
      (multiple-value-bind (octets received eof-p) (receive-octets/keep-fds fd)
        (setf fds (append fds received))
        (let ((messages (parse-messages octets)))
          (when (or messages eof-p)
            (return (values messages fds)))))
      (when (>= (reactor:monotonic-now) deadline)
        (return (values nil fds))))))

(defun fresh-surface (display socket &key (surface-id 6) (compositor-id 3))
  "Bind wl_compositor and create one surface; returns the surface resource."
  (send-bind socket 2 2 "wl_compositor" 1 compositor-id)
  (run-server display)
  (read-events socket)
  (send-message socket compositor-id 0 (lambda (buffer) (wire:put-new-id buffer surface-id)))
  (run-server display)
  (server-object display surface-id))

(defun keymap-octets (fd size)
  "Map FD, copy SIZE octets and unmap: what a client does with a keymap event."
  (let ((mapping (ffi:map-file fd size)))
    (unwind-protect (ffi:mapped-octets mapping 0 size)
      (ffi:unmap-file mapping size))))

(deftest binding-the-seat-sends-its-name-then-capabilities
  (with-seat-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (send-get-registry socket 2)
             (run-server display)
             (read-events socket)
             (send-bind socket 2 3 "wl_seat" 4 4)
             (run-server display)
             (let ((events (read-events socket)))
               (ok (= 2 (length events)) "name, then capabilities")
               (destructuring-bind ((id1 op1 reader1) (id2 op2 reader2)) events
                 (ok (= 4 id1))
                 (ok (= 1 op1) "wl_seat.name is opcode 1")
                 (ok (string= "seat0" (wire:read-string reader1)))
                 (ok (= 4 id2))
                 (ok (= 0 op2) "wl_seat.capabilities is opcode 0")
                 (ok (= 3 (wire:read-uint reader2))
                     "pointer | keyboard"))))
        (ffi:close-fd socket)))))

(deftest a-keyboard-gets-the-keymap-as-a-descriptor-then-repeat-info
  (with-seat-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-seat display socket)
             (send-message socket 4 1 (lambda (buffer) (wire:put-new-id buffer 5)))
             (run-server display)
             (multiple-value-bind (events fds) (read-events-and-fds socket)
               (ok (= 2 (length events)) "keymap, then repeat_info")
               (destructuring-bind ((id1 op1 reader1) (id2 op2 reader2)) events
                 (ok (= 5 id1))
                 (ok (= 0 op1) "wl_keyboard.keymap is opcode 0")
                 ;; The descriptor occupies no octets (D23): the reader holds
                 ;; the format and then the size, and the fd arrives out of band.
                 (let ((format (wire:read-uint reader1))
                       (size (wire:read-uint reader1)))
                   (ok (= 1 format) "xkb_v1")
                   (ok (= (1+ (length *test-keymap*)) size)
                       "the size includes the NUL terminator")
                   (ok (= 1 (length fds)) "exactly one descriptor arrived")
                   ;; What the client would do: map it, read the string, unmap.
                   (when fds
                     (let* ((octets (keymap-octets (first fds) size)))
                       (ffi:close-fd (first fds))
                       (ok (= 0 (aref octets (1- size))) "the keymap is NUL-terminated")
                       (ok (string= *test-keymap*
                                    (sb-ext:octets-to-string
                                     octets :end (1- size)
                                     :external-format :utf-8))
                           "the octets are the keymap the seat was given"))))
                 (ok (= 5 id2))
                 (ok (= 5 op2) "wl_keyboard.repeat_info is opcode 5")
                 (ok (= 25 (wire:read-int reader2)))
                 (ok (= 600 (wire:read-int reader2))))))
        (ffi:close-fd socket)))))

(deftest a-seat-without-the-capability-refuses-the-object
  (with-seat-display (display :capabilities 0)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-seat display socket)
             (send-message socket 4 1 (lambda (buffer) (wire:put-new-id buffer 5)))
             (run-server display)
             (destructuring-bind (object-id code message)
                 (error-reply (read-events socket))
               (ok (= 4 object-id) "the error names the seat")
               (ok (= 0 code) "wl_seat.error.missing_capability")
               (ok (search "keyboard capability" message))))
        (ffi:close-fd socket)))))

(deftest the-seat-release-is-not-available-at-version-four
  (with-seat-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-seat display socket)
             (send-message socket 4 3 nil)             ; wl_seat.release, since 5
             (run-server display)
             (destructuring-bind (object-id code message)
                 (error-reply (read-events socket))
               (declare (ignore message))
               (ok (= 4 object-id) "the error names the wl_seat object")
               (ok (= 1 code) "invalid_method: the version gate, not a missing method")))
        (ffi:close-fd socket)))))

(deftest a-key-reaches-only-the-focused-keyboard
  (with-seat-display (display)
    (let ((socket (raw-connect display))
          (seat (seat-of display)))
      (unwind-protect
           (progn
             (bind-seat display socket)
             (send-message socket 4 1 (lambda (buffer) (wire:put-new-id buffer 5)))
             (run-server display)
             (read-events-and-fds socket)                ; keymap + repeat_info
             (let ((surface (fresh-surface display socket)))
               ;; Nothing focused yet: a key goes nowhere and says so.
               (ok (null (srv:send-key-event seat 1 :pressed))
                   "no focus, no key")
               (srv:set-keyboard-focus seat surface)
               (run-server display)
               (let ((events (read-events socket)))
                 (ok (= 2 (length events)) "enter, then modifiers")
                 (destructuring-bind ((id1 op1 reader1) (id2 op2 reader2)) events
                   (ok (= 5 id1))
                   (ok (= 1 op1) "wl_keyboard.enter is opcode 1")
                   (let ((serial (wire:read-uint reader1)))
                     (ok (plusp serial) "enter carries a serial")
                     (ok (= 6 (wire:read-uint reader1)) "and the focused surface")
                     (ok (null (wire:read-array reader1))
                         "no keys were held, so the array is empty"))
                   (ok (= 5 id2))
                   (ok (= 4 op2) "wl_keyboard.modifiers follows the enter")
                   (ok (integerp (wire:read-uint reader2)) "its own serial")
                   (ok (zerop (wire:read-uint reader2)) "depressed")
                   (ok (zerop (wire:read-uint reader2)) "latched")
                   (ok (zerop (wire:read-uint reader2)) "locked")))
               ;; Now a key, then the modifier state it produced.
               (let ((serial (srv:send-key-event seat 1 :pressed
                                                 :mods-depressed 1)))
                 (ok (integerp serial))
                 (run-server display)
                 (let ((events (read-events socket)))
                   (ok (= 2 (length events)) "key, then modifiers")
                   (destructuring-bind ((id1 op1 reader1) (id2 op2 reader2)) events
                     (ok (= 5 id1))
                     (ok (= 3 op1) "wl_keyboard.key is opcode 3")
                     (ok (= serial (wire:read-uint reader1)))
                     (ok (integerp (wire:read-uint reader1)) "time")
                     (ok (= 1 (wire:read-uint reader1))
                         "the evdev keycode, not the XKB one")
                     (ok (= srv:+wl-keyboard-key-state-pressed+
                            (wire:read-uint reader1)))
                     (ok (= 5 id2))
                     (ok (= 4 op2))
                     (ok (integerp (wire:read-uint reader2)) "its own serial")
                     (ok (= 1 (wire:read-uint reader2))
                         "the depressed mask the seat was told about"))))
               ;; Losing focus says so; the logical key set is the seat's, not the
               ;; surface's, so it still remembers the held key for the next enter.
               (srv:set-keyboard-focus seat nil)
               (run-server display)
               (ok (equal (list 1) (srv:seat-pressed-keys seat)))))
        (ffi:close-fd socket)))))

(deftest pointer-events-follow-the-pointer-focus
  (with-seat-display (display)
    (let ((socket (raw-connect display))
          (seat (seat-of display)))
      (unwind-protect
           (progn
             (bind-seat display socket)
             (send-message socket 4 0 (lambda (buffer) (wire:put-new-id buffer 5)))
             (run-server display)
             (read-events socket)
             (let ((surface (fresh-surface display socket)))
               (srv:set-pointer-focus seat surface 10 20)
               (run-server display)
               (let ((events (read-events socket)))
                 (ok (= 1 (length events)) "enter")
                 (destructuring-bind (id opcode reader) (first events)
                   (ok (= 5 id))
                   (ok (= 0 opcode) "wl_pointer.enter is opcode 0")
                   (ok (integerp (wire:read-uint reader)) "serial")
                   (ok (= 6 (wire:read-uint reader)) "surface")
                   (ok (= 10 (wire:read-fixed reader)) "x, in surface coordinates")
                   (ok (= 20 (wire:read-fixed reader)) "y")))
               (srv:send-pointer-motion seat 30 40)
               (srv:send-pointer-button seat #x110 :pressed)
               (srv:send-pointer-axis seat :vertical 15)
               (run-server display)
               (let ((events (read-events socket)))
                 (ok (= 3 (length events)) "motion, button, axis")
                 (destructuring-bind ((id1 op1 reader1)
                                      (id2 op2 reader2)
                                      (id3 op3 reader3))
                     events
                   (ok (= 5 id1))
                   (ok (= 2 op1) "wl_pointer.motion is opcode 2")
                   (ok (integerp (wire:read-uint reader1)))
                   (ok (= 30 (wire:read-fixed reader1)))
                   (ok (= 40 (wire:read-fixed reader1)))
                   (ok (= 5 id2))
                   (ok (= 3 op2) "wl_pointer.button is opcode 3")
                   (ok (integerp (wire:read-uint reader2)) "serial")
                   (ok (integerp (wire:read-uint reader2)) "time")
                   (ok (= #x110 (wire:read-uint reader2)) "BTN_LEFT")
                   (ok (= srv:+wl-pointer-button-state-pressed+
                          (wire:read-uint reader2)))
                   (ok (= 5 id3))
                   (ok (= 4 op3) "wl_pointer.axis is opcode 4")
                   (ok (integerp (wire:read-uint reader3)) "time")
                   (ok (= srv:+wl-pointer-axis-vertical-scroll+
                          (wire:read-uint reader3)))
                   (ok (= 15 (wire:read-fixed reader3)))))
               ;; Clearing the focus leaves the surface.
               (srv:set-pointer-focus seat nil 0 0)
               (run-server display)
               (let ((events (read-events socket)))
                 (ok (= 1 (length events)))
                 (destructuring-bind (id opcode reader) (first events)
                   (ok (= 5 id))
                   (ok (= 1 opcode) "wl_pointer.leave is opcode 1")))))
        (ffi:close-fd socket)))))

(deftest a-region-is-a-set-of-rectangles
  (with-seat-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-seat display socket)
             (send-bind socket 2 2 "wl_compositor" 1 3)
             (run-server display)
             (read-events socket)
             ;; create_region (7), add 0,0,10,10, then subtract 0,0,5,5.
             (send-message socket 3 1 (lambda (buffer) (wire:put-new-id buffer 7)))
             (run-server display)
             (send-message socket 7 1 (lambda (buffer)
                                        (wire:put-int buffer 0)
                                        (wire:put-int buffer 0)
                                        (wire:put-int buffer 10)
                                        (wire:put-int buffer 10)))
             (send-message socket 7 1 (lambda (buffer)
                                        (wire:put-int buffer 20)
                                        (wire:put-int buffer 20)
                                        (wire:put-int buffer 5)
                                        (wire:put-int buffer 5)))
             (run-server display)
             (let ((region (server-object display 7)))
               (ok (= 2 (length (srv:region-rects region))) "two rectangles")
               (send-message socket 7 2 (lambda (buffer)
                                          (wire:put-int buffer 0)
                                          (wire:put-int buffer 0)
                                          (wire:put-int buffer 5)
                                          (wire:put-int buffer 5)))
               (run-server display)
               (ok (= 3 (length (srv:region-rects region)))
                   "the cut corner becomes three pieces, and the far rectangle stays")
               (ok (srv:region-contains-p region 9 9) "still inside")
               (ok (not (srv:region-contains-p region 1 1)) "the corner is gone")
               (ok (srv:region-contains-p region 22 22) "the second rectangle is untouched")))
        (ffi:close-fd socket)))))

(deftest a-region-is-snapshotted-when-the-surface-commits
  (with-seat-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-seat display socket)
             (send-bind socket 2 2 "wl_compositor" 1 3)
             (run-server display)
             (read-events socket)
             (send-message socket 3 0 (lambda (buffer) (wire:put-new-id buffer 6)))
             (send-message socket 3 1 (lambda (buffer) (wire:put-new-id buffer 7)))
             (run-server display)
             (send-message socket 7 1 (lambda (buffer)
                                        (wire:put-int buffer 3)
                                        (wire:put-int buffer 4)
                                        (wire:put-int buffer 5)
                                        (wire:put-int buffer 6)))
             (run-server display)
             ;; wl_surface.set_opaque_region is opcode 4 (set_input_region is 5).
             (send-message socket 6 4 (lambda (buffer) (wire:put-object buffer 7)))
             (run-server display)
             (let ((surface (server-object display 6)))
               (ok (null (srv:surface-opaque-region surface))
                   "pending until the commit")
               (send-message socket 6 6 nil)             ; commit
               (run-server display)
               (ok (equal '((3 4 5 6)) (srv:surface-opaque-region surface))
                   "committed: the rectangles are copied")
               (ok (null (srv:surface-input-region surface))
                   "the input region was never set")
               ;; The client may destroy the region immediately after setting it.
               (send-message socket 7 0 nil)             ; wl_region.destroy
               (run-server display)
               (ok (equal '((3 4 5 6)) (srv:surface-opaque-region surface))
                   "and outlive the region object")))
        (ffi:close-fd socket)))))

(deftest a-pool-grows-but-never-shrinks
  (with-seat-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-shm display socket)
             (multiple-value-bind (fd size) (make-client-pool 8 4 #xFF00FF00)
               ;; The test's own memfd, grown the way a client grows its pool.
               (declare (ignore size))
               (unwind-protect
                    (progn
                      (send-create-pool socket 4 fd 128 :shm-id 3)
                      (run-server display)
                      (let ((pool (server-object display 4)))
                        (ok (= 128 (srv:shm-pool-size pool)))
                        ;; The file must grow first; the client does that itself.
                        (ffi:set-file-size fd 512)
                        (send-message socket 4 2 (lambda (buffer) (wire:put-int buffer 512)))
                        (run-server display)
                        (ok (= 512 (srv:shm-pool-size pool)) "the pool grew")
                        (ok (= 512 (length (ffi:mapped-octets
                                            (srv:shm-pool-mapping pool) 0 512)))
                            "and the mapping grew with it")
                        ;; Shrinking is not what resize is for.
                        (send-message socket 4 2 (lambda (buffer) (wire:put-int buffer 256)))
                        (run-server display)
                        (destructuring-bind (object-id code message)
                            (error-reply (read-events socket))
                          (ok (= 4 object-id))
                          (ok (= srv:+wl-shm-error-invalid-fd+ code))
                          (ok (search "only grow" message)))))
                 (ffi:close-fd fd))))
        (ffi:close-fd socket)))))

(deftest a-pool-cannot-be-grown-past-its-file
  (with-seat-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-shm display socket)
             (multiple-value-bind (fd size) (make-client-pool 8 4 #xFF00FF00)
               (unwind-protect
                    (progn
                      (send-create-pool socket 4 fd size :shm-id 3)
                      (run-server display)
                      ;; Ask for more than the file holds: mmap would succeed and
                      ;; the renderer would take SIGBUS later, which is exactly the
                      ;; trap the lseek check exists to avoid.
                      (send-message socket 4 2
                                    (lambda (buffer) (wire:put-int buffer (* 4 size))))
                      (run-server display)
                      (destructuring-bind (object-id code message)
                          (error-reply (read-events socket))
                        (ok (= 4 object-id))
                        (ok (= srv:+wl-shm-error-invalid-fd+ code))
                        (ok (search "file is" message))))
                 (ffi:close-fd fd))))
        (ffi:close-fd socket)))))

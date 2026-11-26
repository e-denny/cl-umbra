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

(deftest a-request-with-no-method-is-an-implementation-error
  ;; wl_display.error.implementation is what the dispatch layer says when a request
  ;; exists in the schema but nothing implements it on the object's class -- the
  ;; honest "not built yet" (D9).  Every xdg-shell v1 request is implemented now, so
  ;; the subject here is a bare resource class: a wl_output bound as SRV:RESOURCE
  ;; answers nothing, which is exactly the shape a half-written compositor has.
  (with-display (display)
    (srv:add-global display
                    :interface "wl_output"
                    :version 4
                    :resource-class 'srv:resource)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (send-get-registry socket 2)
             (run-server display)
             (read-events socket)                    ; the global announcement
             (send-bind socket 2 1 "wl_output" 4 3)
             (run-server display)
             (send-message socket 3 0)               ; wl_output.release
             (run-server display)
             (destructuring-bind (object-id code message)
                 (error-reply (read-events socket))
               (ok (= 3 object-id) "the error names the object that cannot answer")
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

(deftest an-input-region-survives-being-destroyed-before-the-commit
  ;; weston's own clients do this: set_input_region, destroy the wl_region, then
  ;; commit.  Reading the rectangles at commit time would read a region that no
  ;; longer has any (found by weston-eventdemo, whose window became
  ;; input-transparent at (0,0) -- an inset input region is exactly the shape of
  ;; thing that bug turns into silence).
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
                                        (wire:put-int buffer 4)
                                        (wire:put-int buffer 4)
                                        (wire:put-int buffer 8)
                                        (wire:put-int buffer 6)))
             (run-server display)
             ;; wl_surface.set_input_region is opcode 5; then destroy the region
             ;; (opcode 0) *before* committing (opcode 6).
             (send-message socket 6 5 (lambda (buffer) (wire:put-object buffer 7)))
             (send-message socket 7 0 nil)
             (send-message socket 6 6 nil)
             (run-server display)
             (let ((surface (server-object display 6)))
               (ok (equal '((4 4 8 6)) (srv:surface-input-region surface))
                   "the rectangles were copied when the request arrived")
               (ok (not (eq :empty (srv:surface-input-region surface)))
                   "and an empty region is not what a destroyed one becomes")))
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

;;; ---------------------------------------------------------------------------
;;; Serials and grab requests
;;; ---------------------------------------------------------------------------
;;
;; A serial is a capability: it is meaningful only because *we* issued it in
;; response to an input event.  These are the two halves of the rule -- is the
;; number ours and recent, and is the asking surface the one the seat is on --
;; which together decide whether an xdg_toplevel.move becomes a grab (D33).

(deftest only-recent-serials-are-valid
  (with-seat-display (display)
    (let* ((seat (seat-of display))
           (serial (srv:display-next-serial display)))
      (ok (srv:valid-serial-p seat serial) "a serial we just issued is valid")
      (ok (not (srv:valid-serial-p seat (1+ serial)))
          "one we have never issued is not")
      (ok (not (srv:valid-serial-p seat 0)) "and zero is never a capability")
      (dotimes (i 100) (srv:display-next-serial display))
      (ok (not (srv:valid-serial-p seat serial))
          "a serial older than the window is no longer valid"))))

(deftest a-move-request-needs-our-serial-and-the-focus
  (with-seat-display (display)
    (let* ((socket (raw-connect display))
           (seat (seat-of display)))
      (unwind-protect
           (progn
             (bind-seat display socket)
             (run-server display)
             (read-events socket)
             (let ((surface (fresh-surface display socket))
                   (serial (srv:display-next-serial display)))
               (srv:set-keyboard-focus seat surface)
               (ok (srv:grab-request-acceptable-p seat surface serial)
                   "a recent serial plus keyboard focus is acceptable")
               (ok (not (srv:grab-request-acceptable-p seat surface (+ serial 1000)))
                   "an invented serial is refused")
               (srv:set-keyboard-focus seat nil)
               (ok (not (srv:grab-request-acceptable-p seat surface serial))
                   "a real serial without focus is refused too")))
        (ffi:close-fd socket)))))

;;; ---------------------------------------------------------------------------
;;; xdg_popup and xdg_positioner
;;;
;;; Two kinds of test, deliberately, for the same reason as everywhere else here:
;;;
;;;   * the positioner's *arithmetic*, as pure functions -- a flip that is one pixel
;;;     off is invisible in a screenshot and obvious in a number;
;;;   * the popup's state machine over raw messages -- only a client that can make
;;;     the wrong request can prove that we refuse it.
;;;
;;; Opcodes used: wl_compositor.create_surface 0, xdg_wm_base.get_xdg_surface 2,
;;; .create_positioner 1, xdg_positioner.set_size 1, .set_anchor_rect 2,
;;; .set_anchor 3, .set_gravity 4, .set_constraint_adjustment 5, .set_offset 6,
;;; xdg_surface.get_popup 2, .ack_configure 4, xdg_popup.grab 1, .destroy 0.
;;; ---------------------------------------------------------------------------

(defun test-rule (&key (width 100) (height 60) (rect '(10 20 30 40))
                       (anchor 8) (gravity 8) (adjustment 0) (offset '(0 0)))
  "A positioner rule plist; the defaults are a 100x60 popup hung off a corner."
  (list :width width :height height :anchor-rect rect :anchor anchor
        :gravity gravity :constraint adjustment :offset offset))

(defmacro edges (form)
  "The values FORM produces, as a list: (edges (f x)) is (multiple-value-list (f x))."
  `(multiple-value-list ,form))

(deftest an-anchor-point-is-a-corner-an-edge-middle-or-the-centre
  (let ((rect '(10 20 30 40)))                  ; x 10..40, y 20..60
    (ok (equal '(10 20) (edges (srv:anchor-point rect 5))) "top-left corner")
    (ok (equal '(40 60) (edges (srv:anchor-point rect 8))) "bottom-right corner")
    (ok (equal '(10 40) (edges (srv:anchor-point rect 3))) "middle of the left edge")
    (ok (equal '(25 60) (edges (srv:anchor-point rect 2))) "middle of the bottom edge")
    (ok (equal '(25 40) (edges (srv:anchor-point rect 0)))
        "no anchor: the centre, which is the only useful default")))

(deftest a-popup-is-placed-towards-its-gravity
  ;; Anchor bottom-right of the rectangle (40, 60); gravity bottom-right means the
  ;; popup hangs down and right from that point, i.e. its top-left corner *is* it.
  (ok (equal '(40 60) (edges (srv:popup-position (test-rule) 8 8))))
  ;; Top-left gravity and anchor put the popup's bottom-right corner on it.
  (ok (equal '(-90 -40) (edges (srv:popup-position (test-rule) 5 5))))
  ;; A gravity with no horizontal direction centres the popup on the anchor.
  ;; Anchor bottom-right (40, 60); gravity `bottom' has no horizontal direction, so
  ;; the popup is centred across and its bottom edge sits on the anchor: x = 40 - 50.
  (ok (equal '(-10 60) (edges (srv:popup-position (test-rule) 8 2)))
      "bottom gravity: centred across, bottom edge on the anchor")
  ;; The offset is added after the gravity, which is what makes it an offset.
  (ok (equal '(45 53) (edges (srv:popup-position (test-rule :offset '(5 -7)) 8 8)))))

(deftest a-constrained-popup-flips-then-slides-then-resizes
  (let ((rule (test-rule :rect '(140 60 10 10))))     ; anchor point (150, 70)
    ;; Nothing allowed: the position is the client's, even outside the output.
    (ok (equal '(150 70 100 60) (edges (srv:place-popup rule '(0 0 200 100))))
        "adjustment 0 means do not move it")
    ;; Flip first, and keep it only when the flipped position fits: here both axes
    ;; flip to (40, 0), which is inside.
    (ok (equal '(40 0 100 60)
               (edges (srv:place-popup (test-rule :rect '(140 60 10 10)
                                                  :adjustment (logior 4 8))
                                       '(0 0 200 100))))
        "flip_x and flip_y invert anchor and gravity")
    ;; Slide clamps the popup into the box when no flip was asked for.
    (ok (equal '(100 40 100 60)
               (edges (srv:place-popup (test-rule :rect '(140 60 10 10)
                                                  :adjustment 3)
                                       '(0 0 200 100))))
        "slide_x and slide_y move it the shortest way inside")
    ;; A popup bigger than the box cannot be unconstrained: it covers the box.
    (ok (equal '(0 70 300 60)
               (edges (srv:place-popup (test-rule :width 300 :rect '(140 60 10 10)
                                                  :adjustment 1)
                                       '(0 0 200 100))))
        "an oversized popup slides until it covers the box, not out of it")
    ;; Resize shrinks it against the box's far edge.
    (ok (equal '(50 10 70 30)
               (edges (srv:place-popup (test-rule :rect '(40 0 10 10)
                                                  :adjustment (logior 16 32))
                                       '(0 0 120 40))))
        "resize_x and resize_y shrink the popup to fit")))

(deftest a-flip-that-is-still-constrained-is-reverted
  ;; Bottom-right anchor, bottom-right gravity, a popup taller than the box is wide:
  ;; flipping the y axis puts it above the anchor *and* off the top, so the
  ;; unflipped (constrained) position is kept -- the XML requires exactly that.
  (let ((rule (test-rule :height 200 :rect '(10 10 10 10) :adjustment 8)))
    (ok (equal '(20 20 100 200) (edges (srv:place-popup rule '(0 0 400 100))))
        "the position before the adjustment stands")))

;;; ---------------------------------------------------------------------------
;;; The popup state machine
;;; ---------------------------------------------------------------------------

(defun create-positioner (display socket &key (id 30) (width 100) (height 60)
                                            (rect '(10 20 30 40))
                                            (anchor 8) (gravity 8)
                                            (adjustment 0) (offset '(0 0)))
  "create_positioner (id), and fill it in: size, anchor rect, anchor, gravity,
adjustment and offset.  WIDTH/RECT of NIL leave that rule unset (an incomplete
positioner is the negative test)."
  (send-message socket 4 1 (lambda (buffer) (wire:put-new-id buffer id)))
  (run-server display)
  (when width
    (send-message socket id 1 (lambda (buffer)
                               (wire:put-int buffer width)
                               (wire:put-int buffer height))))
  (when rect
    (send-message socket id 2 (lambda (buffer)
                               (dolist (value rect) (wire:put-int buffer value)))))
  (send-message socket id 3 (lambda (buffer) (wire:put-uint buffer anchor)))
  (send-message socket id 4 (lambda (buffer) (wire:put-uint buffer gravity)))
  (send-message socket id 5 (lambda (buffer) (wire:put-uint buffer adjustment)))
  (send-message socket id 6 (lambda (buffer)
                             (wire:put-int buffer (first offset))
                             (wire:put-int buffer (second offset))))
  (run-server display))

(defmacro with-popup-display ((display) &body body)
  "A display offering wl_shm (global 1), wl_compositor (2), xdg_wm_base (3) and
wl_seat (4).  The seat matters because a popup grab names one, and its serials are
only valid because this display issued them."
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
     (let ((seat (srv:make-seat ,display :name "seat0" :capabilities 3)))
       (srv:add-seat-global ,display seat)
       (locally ,@body))))

(defun bind-popup (display socket)
  "get_registry (2), then bind wl_shm as 5, wl_compositor as 3, xdg_wm_base as 4 and
wl_seat as 6: the same layout as WITH-XDG-DISPLAY plus a seat."
  (send-get-registry socket 2)
  (run-server display)
  (read-events socket)                                  ; four global announcements
  (send-bind socket 2 1 "wl_shm" 1 5)
  (send-bind socket 2 2 "wl_compositor" 1 3)
  (send-bind socket 2 3 "xdg_wm_base" 1 4)
  (send-bind socket 2 4 "wl_seat" 4 6)
  (run-server display)
  (read-events socket)                                  ; shm formats, seat name and caps
  socket)

(defun make-popup (display socket &key (surface 40) (shell 41) (popup 42)
                                 (parent 11) (positioner 30))
  "A wl_surface, an xdg_surface and a popup role for it; nothing committed."
  (send-message socket 3 0 (lambda (buffer) (wire:put-new-id buffer surface)))
  (send-message socket 4 2 (lambda (buffer)
                             (wire:put-new-id buffer shell)
                             (wire:put-object buffer surface)))
  (send-message socket shell 2 (lambda (buffer)
                                 (wire:put-new-id buffer popup)
                                 (wire:put-object buffer parent)
                                 (wire:put-object buffer positioner)))
  (run-server display))

(defun read-popup-configure (socket popup-id shell-id)
  "Decode xdg_popup.configure + xdg_surface.configure.
Returns (values x y width height serial)."
  (let ((events (read-events socket)))
    (ok (= 2 (length events))
        (format nil "a popup configure and a surface configure, got ~D message~:P"
                (length events)))
    (destructuring-bind ((first-id first-opcode first-reader)
                         (second-id second-opcode second-reader))
        events
      (ok (= popup-id first-id) "xdg_popup.configure arrives on the popup")
      (ok (= 0 first-opcode) "xdg_popup.configure is opcode 0")
      (ok (= shell-id second-id) "xdg_surface.configure follows it")
      (ok (= 0 second-opcode) "xdg_surface.configure is opcode 0")
      (let ((x (wire:read-int first-reader))
            (y (wire:read-int first-reader))
            (width (wire:read-int first-reader))
            (height (wire:read-int first-reader)))
        (values x y width height (wire:read-uint second-reader))))))

(deftest a-popup-is-configured-where-the-positioner-says
  (with-xdg-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-xdg display socket)
             (make-toplevel display socket)
             (commit-surface display socket)
             (multiple-value-bind (width height states serial)
                 (read-configure socket)
               (declare (ignore width height states))
               (ack-configure socket serial))
             (create-positioner display socket)
             (make-popup display socket)
             (let ((popup (server-object display 42)))
               (ok (eq (server-object display 11) (srv:xdg-popup-parent popup))
                   "the popup points at its parent xdg_surface")
               (ok (eq (server-object display 12) (srv:xdg-popup-toplevel popup))
                   "and the walk up its parent chain finds the toplevel")
               (ok (equal (list popup) (srv:xdg-toplevel-popups (server-object display 12)))
                   "a new popup is in its toplevel's stack")
               (commit-surface display socket 40)
               (multiple-value-bind (x y popup-width popup-height configure-serial)
                   (read-popup-configure socket 42 41)
                 ;; Anchor bottom-right of (10 20 30 40) is (40, 60), and
                 ;; bottom-right gravity hangs the popup down and right from it.
                 (ok (= 40 x) "x is the anchor point, not the rectangle's origin")
                 (ok (= 60 y))
                 (ok (= 100 popup-width) "the size is the positioner's, not the client's choice")
                 (ok (= 60 popup-height))
                 (ok (equal (list 40 60 100 60) (srv:xdg-popup-geometry popup))
                     "the placement is recorded for the compositor to draw")
                 (ok (srv:xdg-surface-configured-p (server-object display 41)))
                 (ok (equal (list configure-serial)
                            (srv:xdg-surface-pending-serials (server-object display 41)))
                     "the popup's serial waits for its ack")
                 ;; The rules were copied at get_popup, so reusing the positioner
                 ;; now changes nothing about this popup.
                 (send-message socket 30 1 (lambda (buffer)
                                            (wire:put-int buffer 10)
                                            (wire:put-int buffer 10)))
                 (run-server display)
                 (ok (equal (list 10 10)
                            (srv:xdg-positioner-size (server-object display 30))))
                 (ok (equal (list 40 60 100 60) (srv:xdg-popup-geometry popup))
                     "the popup kept the copy it was made from")
                 ;; v1 popups are configured once.
                 (send-message socket 40 6)
                 (run-server display)
                 (ok (null (read-events socket :timeout 0.05))
                     "a second commit is not a second configure")
                 (ack-configure socket configure-serial 41)
                 (run-server display)
                 (ok (srv:xdg-surface-acknowledged-p (server-object display 41))
                     "and the serial is consumed by ack_configure"))))
        (ffi:close-fd socket)))))

(deftest a-popup-maps-with-a-buffer-and-unmaps-without-one
  (with-xdg-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-xdg display socket)
             (make-toplevel display socket)
             (commit-surface display socket)
             (multiple-value-bind (width height states serial)
                 (read-configure socket)
               (declare (ignore width height states))
               (ack-configure socket serial))
             (create-positioner display socket)
             (make-popup display socket)
             (commit-surface display socket 40)
             (multiple-value-bind (x y width height serial)
                 (read-popup-configure socket 42 41)
               (declare (ignore x y width height))
               (ack-configure socket serial 41))
             (make-buffer-on-the-shm-global display socket)
             (attach-buffer socket 21 40)
             (send-message socket 40 2 (lambda (buffer)
                                        (wire:put-int buffer 0) (wire:put-int buffer 0)
                                        (wire:put-int buffer 8) (wire:put-int buffer 4)))
             (commit-surface display socket 40)
             (ok (srv:xdg-popup-mapped-p (server-object display 42)) "the popup is mapped")
             (ok (srv:xdg-surface-mapped-p (server-object display 41)))
             (ok (srv:surface-mapped-p (server-object display 40)))
             ;; An attach of NIL is an unmap, exactly as for a toplevel.
             (send-message socket 40 1 (lambda (buffer)
                                        (wire:put-object buffer nil)
                                        (wire:put-int buffer 0)
                                        (wire:put-int buffer 0)))
             (commit-surface display socket 40)
             (ok (not (srv:xdg-popup-mapped-p (server-object display 42)))
                 "detaching the buffer unmaps it again"))
        (ffi:close-fd socket)))))

(deftest only-the-topmost-popup-may-be-destroyed
  (with-xdg-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-xdg display socket)
             (make-toplevel display socket)
             (commit-surface display socket)
             (multiple-value-bind (width height states serial)
                 (read-configure socket)
               (declare (ignore width height states))
               (ack-configure socket serial))
             (create-positioner display socket)
             (make-popup display socket)
             (make-popup display socket :surface 43 :shell 44 :popup 45)
             (send-message socket 42 0)                ; destroy the older popup
             (run-server display)
             (destructuring-bind (object-id code message)
                 (error-reply (read-events socket))
               (ok (= 4 object-id) "the error comes from xdg_wm_base")
               (ok (= 2 code) "xdg_wm_base.error.not_the_topmost_popup")
               (ok (search "not the topmost" message))))
        (ffi:close-fd socket)))
    ;; And the topmost one may be destroyed, with no error at all.
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-xdg display socket)
             (make-toplevel display socket)
             (create-positioner display socket)
             (make-popup display socket)
             (make-popup display socket :surface 43 :shell 44 :popup 45)
             (send-message socket 45 0)
             (run-server display)
             (ok (null (server-object display 45)) "the id is gone")
             ;; Destroying a resource sends wl_display.delete_id, so the id comes
             ;; back; anything else here would be an error.
             (let ((events (read-events socket :timeout 0.05)))
               (ok (equal (list 1) (mapcar #'first events))
                   "no error: the newest popup is the client's to destroy")
               (ok (equal (list 45)
                          (mapcar (lambda (event) (wire:read-uint (third event))) events))
                   "the id is handed back to the client"))
             )
        (ffi:close-fd socket)))))

(deftest a-popup-grab-needs-a-serial-we-issued
  ;; A grab the compositor cannot honour is not an error: the popup is dismissed.
  (with-xdg-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-xdg display socket)
             (make-toplevel display socket)
             (create-positioner display socket)
             (make-popup display socket)
             ;; The seat argument names the shm global: not a seat, so no grab.
             (send-message socket 42 1 (lambda (buffer)
                                        (wire:put-object buffer 5)
                                        (wire:put-uint buffer 0)))
             (run-server display)
             (let ((events (read-events socket)))
               (ok (equal (list 42) (mapcar #'first events))
                   "popup_done arrives on the popup")
               (ok (= 1 (second (first events))) "xdg_popup.popup_done is opcode 1")
               (ok (srv:xdg-popup-dismissed-p (server-object display 42)))
               (ok (not (srv:surface-mapped-p (server-object display 40)))
                   "and the surface is unmapped at the same time")))
        (ffi:close-fd socket)))))

(deftest a-popup-grab-with-our-serial-is-accepted
  (with-popup-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-popup display socket)
             (make-toplevel display socket)
             (create-positioner display socket)
             (make-popup display socket)
             (let ((serial (srv:display-next-serial display)))
               (send-message socket 42 1 (lambda (buffer)
                                          (wire:put-object buffer 6)   ; the wl_seat
                                          (wire:put-uint buffer serial)))
               (run-server display)
               (ok (srv:xdg-popup-grabbed-p (server-object display 42))
                   "a serial this display issued is a grab we can honour")
               (ok (null (read-events socket :timeout 0.05))
                   "and nothing is dismissed")))
        (ffi:close-fd socket)))))

(deftest a-popup-may-not-grab-after-it-is-mapped
  (with-xdg-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-xdg display socket)
             (make-toplevel display socket)
             (commit-surface display socket)
             (multiple-value-bind (width height states serial)
                 (read-configure socket)
               (declare (ignore width height states))
               (ack-configure socket serial))
             (create-positioner display socket)
             (make-popup display socket)
             (commit-surface display socket 40)
             (multiple-value-bind (x y width height serial)
                 (read-popup-configure socket 42 41)
               (declare (ignore x y width height))
               (ack-configure socket serial 41))
             (make-buffer-on-the-shm-global display socket)
             (attach-buffer socket 21 40)
             (commit-surface display socket 40)
             (send-message socket 42 1 (lambda (buffer)
                                        (wire:put-object buffer 5)
                                        (wire:put-uint buffer 0)))
             (run-server display)
             (destructuring-bind (object-id code message)
                 (error-reply (read-events socket))
               (ok (= 42 object-id))
               (ok (= 0 code) "xdg_popup.error.invalid_grab")
               (ok (search "after the popup was mapped" message))))
        (ffi:close-fd socket)))))

(deftest a-popup-under-a-popup-without-a-grab-is-refused
  (with-xdg-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-xdg display socket)
             (make-toplevel display socket)
             (create-positioner display socket)
             (make-popup display socket)
             ;; A submenu of a menu: the parent must itself have a grab.
             (make-popup display socket :surface 43 :shell 44 :popup 45
                                       :parent 41)
             (ok (eq (server-object display 41)
                     (srv:xdg-popup-parent (server-object display 45)))
                 "the submenu's parent is the parent popup's xdg_surface")
             (ok (eq (server-object display 42)
                     (srv:xdg-surface-role (server-object display 41)))
                 "whose role is the menu, not the window")
             (send-message socket 45 1 (lambda (buffer)
                                        (wire:put-object buffer 5)
                                        (wire:put-uint buffer 1)))
             (run-server display)
             (destructuring-bind (object-id code message)
                 (error-reply (read-events socket))
               (ok (= 4 object-id))
               (ok (= 3 code) "xdg_wm_base.error.invalid_popup_parent")
               (ok (search "has no explicit grab" message))))
        (ffi:close-fd socket)))))

(deftest a-popup-parent-must-have-a-role
  (with-xdg-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-xdg display socket)
             (make-toplevel display socket)
             ;; An xdg_surface with no role: nothing to be a child of.
             (send-message socket 3 0 (lambda (buffer) (wire:put-new-id buffer 13)))
             (send-message socket 4 2 (lambda (buffer)
                                        (wire:put-new-id buffer 14)
                                        (wire:put-object buffer 13)))
             (run-server display)
             (create-positioner display socket)
             (make-popup display socket :parent 14)
             (run-server display)
             (destructuring-bind (object-id code message)
                 (error-reply (read-events socket))
               (ok (= 41 object-id) "the error names the popup's xdg_surface")
               (ok (= 3 code) "xdg_wm_base.error.invalid_popup_parent")
               (ok (search "no role" message))))
        (ffi:close-fd socket)))))

(deftest a-popup-with-no-parent-is-never-configured
  ;; The v1 XML allows a null parent when "some other protocol" will supply one; no
  ;; other protocol here can, so the honest answer is not to map it rather than to
  ;; invent a position.
  (with-xdg-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-xdg display socket)
             (make-toplevel display socket)
             (create-positioner display socket)
             (make-popup display socket :parent nil)
             (commit-surface display socket 40)
             (let ((popup (server-object display 42)))
               (ok (null (srv:xdg-popup-parent popup)))
               (ok (null (srv:xdg-popup-geometry popup)) "no placement was invented")
               (ok (not (srv:xdg-surface-configured-p (server-object display 41))))
               (ok (null (read-events socket :timeout 0.05))
                   "and the client is told nothing it cannot act on")))
        (ffi:close-fd socket)))))

(deftest a-positioner-must-be-complete-before-a-popup-can-use-it
  ;; A positioner with a size but no anchor rectangle is "incomplete" by the spec's
  ;; definition, and the error is xdg_wm_base's (invalid_positioner) -- not the
  ;; positioner's own, because the *popup* is what cannot be made.
  (with-xdg-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-xdg display socket)
             (make-toplevel display socket)
             (create-positioner display socket :rect nil)
             (ok (null (srv:xdg-positioner-anchor-rect (server-object display 30)))
                 "the positioner has a size and no anchor rectangle")
             (make-popup display socket)
             (run-server display)
             (destructuring-bind (object-id code message)
                 (error-reply (read-events socket))
               (ok (= 41 object-id) "the error names the xdg_surface that asked")
               (ok (= 5 code) "xdg_wm_base.error.invalid_positioner")
               (ok (search "anchor rectangle" message))))
        (ffi:close-fd socket)))))

(deftest a-popup-cannot-be-its-own-parent
  (with-xdg-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-xdg display socket)
             (make-toplevel display socket)
             (create-positioner display socket)
             ;; The parent argument names the popup's *own* xdg_surface, which is
             ;; not a role yet -- so this is caught as "no role" or "its own
             ;; parent" depending on the order of the checks; what matters is that
             ;; it is refused rather than made into a cycle.
             (make-popup display socket :parent 41)
             (run-server display)
             (destructuring-bind (object-id code message)
                 (error-reply (read-events socket))
               (ok (= 41 object-id))
               (ok (= 3 code) "xdg_wm_base.error.invalid_popup_parent")
               (ok (or (search "its own popup parent" message)
                       (search "has no role" message))
                   (format nil "and it says which rule was broken: ~S" message))))
        (ffi:close-fd socket)))))

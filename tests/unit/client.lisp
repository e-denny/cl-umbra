;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; Client tests: a real socket pair standing in for a compositor, real
;;;; messages encoded with WAYLAND.WIRE, and the generated WAYLAND package doing
;;;; the schema work.
;;;;
;;;; Nothing here starts a compositor thread.  The "server" is the other end of
;;;; a socket pair: it writes the bytes a compositor would write, and the client
;;;; under test has no way to tell the difference.  What is *not* covered is
;;;; interoperation with libwayland itself; that arrives with the phase-0 gate
;;;; and a real compositor.

(in-package #:cl-user)

(defpackage #:wayland.test.client
  (:use #:cl #:wayland.test)
  (:local-nicknames (#:wc #:wayland.client)
                    (#:wire #:wayland.wire)
                    (#:io #:wayland.io)
                    (#:ffi #:wayland.ffi)
                    (#:wp #:wayland.protocol))
  (:documentation "Tests for wayland.client (phase-0 minimal client)."))

(in-package #:wayland.test.client)

;;; ---------------------------------------------------------------------------
;;; A server made of a socket pair
;;; ---------------------------------------------------------------------------

(defmacro with-display ((display peer) &body body)
  "A display connected to PEER, the far end of a socket pair."
  (let ((client (gensym "CLIENT")))
    `(multiple-value-bind (,client ,peer) (ffi:make-socket-pair)
       (let ((,display (wc:make-display-from-fd ,client)))
         (unwind-protect (locally ,@body)
           (wc:disconnect ,display)
           (ffi:close-fd ,peer))))))

(defun encode-message (object-id opcode typed-arguments)
  "TYPOED-ARGUMENTS is a flat list: type, value, type, value, ..."
  (let* ((buffer (wire:make-message-buffer))
         (start (wire:begin-message buffer object-id opcode)))
    (loop for (type value) on typed-arguments by #'cddr
          do (ecase type
               (:uint (wire:put-uint buffer value))
               (:int (wire:put-int buffer value))
               (:string (wire:put-string buffer value))
               (:object (wire:put-object buffer (if (typep value 'wc:proxy)
                                                    (wc:proxy-id value)
                                                    value)))
               (:new-id (wire:put-new-id buffer (if (typep value 'wc:proxy)
                                                    (wc:proxy-id value)
                                                    value)))))
    (wire:end-message buffer start)
    buffer))

(defun emit (peer object-id opcode &rest typed-arguments)
  "Write one message to the peer; returns the buffer it went out in."
  (let ((buffer (encode-message object-id opcode typed-arguments)))
    (io:flush-buffer peer buffer)
    buffer))

(defun read-message (fd &key (size 4096))
  "Everything the client wrote, as octets."
  (let ((octets (make-array size :element-type '(unsigned-byte 8))))
    (multiple-value-bind (count fds truncated-p eof-p)
        (ffi:receive-with-ancillary fd octets 0 size :fds-max 8)
      (declare (ignore eof-p))
      (dolist (descriptor fds) (ffi:close-fd descriptor))
      (is (not truncated-p) "no descriptor truncation expected in these tests")
      (subseq octets 0 count))))

(defun read-messages (fd)
  "Every complete message the client wrote, as (object-id opcode reader) lists."
  (let ((octets (read-message fd))
        (messages '())
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

(defun dispatch-until (display stop &key (timeout 2))
  "Dispatch up to TIMEOUT seconds, stopping when STOP returns true."
  (let ((deadline (+ (wayland.reactor:monotonic-now) timeout)))
    (loop until (funcall stop)
          do (let ((remaining (- deadline (wayland.reactor:monotonic-now))))
               (when (<= remaining 0)
                 (return nil))
               (wc:dispatch display :timeout remaining)))))

;;; ---------------------------------------------------------------------------
;;; Where the socket is
;;; ---------------------------------------------------------------------------

(deftest socket-path-rules
  (is-equal "/run/user/1000/wayland-0"
            (wc:socket-path :display-name "wayland-0" :runtime-dir "/run/user/1000"))
  (is-equal "/tmp/nested-wayland"
            (wc:socket-path :display-name "/tmp/nested-wayland" :runtime-dir "/run/user/1000"))
  (is-equal "/run/user/1000/wayland-7"
            (wc:socket-path :display-name "wayland-7" :runtime-dir "/run/user/1000/"))
  (is-equal "wayland-0"
            (pathname-name (pathname (wc:socket-path :display-name nil
                                                     :runtime-dir "/run/user/1000"))))
  (is (plusp (length (wc:socket-path))))
  (signals wc:client-error
    (wc:socket-path :display-name "wayland-0" :runtime-dir nil))
  (signals wc:client-error
    (wc:socket-path :display-name "" :runtime-dir "/run/user/1000")))

(deftest connect-reports-a-missing-socket
  (signals wc:connection-failed
    (wc:connect :path "/nonexistent-wayland-directory/wayland-0")))

;;; ---------------------------------------------------------------------------
;;; Requests
;;; ---------------------------------------------------------------------------

(deftest get-registry-sends-display-request
  (with-display (display peer)
    (let ((registry (wc:wl-display.get-registry display)))
      (is-equal "wl_registry" (wp:interface-name (wc:proxy-interface registry)))
      (is-equal wc:+first-client-id+ (wc:proxy-id registry))
      (is (eq registry (wc:object-for-id display (wc:proxy-id registry))))
      (is (wc:flush display))
      (let ((messages (read-messages peer)))
        (is-equal 1 (length messages))
        (destructuring-bind (object-id opcode reader) (first messages)
          (is-equal 1 object-id :description "the request goes to wl_display")
          (is-equal 1 opcode :description "wl_display.get_registry")
          (is-equal (wc:proxy-id registry) (wire:read-uint reader) :description "new id")
          (is (wire:reader-done-p reader)))))))

(deftest ids-are-allocated-in-order
  (with-display (display peer)
    (let ((first (wc:wl-display.get-registry display))
          (second (wc:wl-display.get-registry display))
          (callback (wc:wl-display.sync display)))
      (is-equal '(2 3 4) (list (wc:proxy-id first) (wc:proxy-id second)
                               (wc:proxy-id callback))))))

(deftest requests-not-sent-until-flushed
  (with-display (display peer)
    (wc:wl-display.get-registry display)
    (is (plusp (wire:buffer-size (wc:display-output display)))
        "the request is encoded into the out buffer")
    (is (zerop (length (read-message peer)))
        "and nothing has reached the socket yet")
    (wc:flush display)
    (is (plusp (length (read-message peer))))))

(deftest bind-encodes-the-four-wire-arguments
  (with-display (display peer)
    (let* ((registry (wc:wl-display.get-registry display))
           (compositor (wc:wl-registry.bind registry 5 "wl_compositor" 3)))
      (is-equal "wl_compositor" (wp:interface-name (wc:proxy-interface compositor)))
      (is-equal 3 (wc:proxy-version compositor))
      (wc:flush display)
      (let ((messages (read-messages peer)))
        (is-equal 2 (length messages) :description "get_registry and bind")
        (destructuring-bind (object-id opcode reader) (second messages)
          (is-equal (wc:proxy-id registry) object-id)
          (is-equal 0 opcode :description "wl_registry.bind")
          (is-equal 5 (wire:read-uint reader) :description "name")
          (is-equal "wl_compositor" (wire:read-string reader) :description "interface")
          (is-equal 3 (wire:read-uint reader) :description "version")
          (is-equal (wc:proxy-id compositor) (wire:read-uint reader) :description "id")
          (is (wire:reader-done-p reader)))))))

(deftest bind-clamps-the-version-to-the-interface
  (with-display (display peer)
    (let* ((registry (wc:wl-display.get-registry display))
           (interface (wp:find-interface "wl_compositor"))
           (bound (wc:wl-registry.bind registry 5 "wl_compositor" 999)))
      (is-equal (wp:interface-version interface) (wc:proxy-version bound))
      (signals wc:client-error
        (wc:wl-registry.bind registry 6 "wl_compositor" 0)))))

(deftest bind-refuses-an-unknown-interface
  (with-display (display peer)
    (let ((registry (wc:wl-display.get-registry display)))
      (signals wp:invalid-schema
        (wc:wl-registry.bind registry 1 "not_a_protocol_yet" 1)))))

(deftest argument-checks-follow-the-xml
  (with-display (display peer)
    (let ((source (wc:register-proxy display 4 "wl_data_source"))
          (subsurface (wc:register-proxy display 5 "wl_subsurface")))
      ;; offer(mime_type :string) is not nullable.
      (signals wc:client-error
        (wc:send-request source (wc:interface-request "wl_data_source" 0) nil))
      ;; place_above(sibling :object) is not nullable either.
      (signals wc:client-error
        (wc:send-request subsurface (wc:interface-request "wl_subsurface" 2) nil))
      ;; Wrong arity is a caller bug, caught rather than silently encoded.
      (signals wc:client-error
        (wc:send-request source (wc:interface-request "wl_data_source" 0) "text/plain" 1)))))

;;; ---------------------------------------------------------------------------
;;; Events
;;; ---------------------------------------------------------------------------

(deftest hooks-receive-events-in-order
  (with-display (display peer)
    (let* ((registry (wc:wl-display.get-registry display))
           (events '()))
      (push (lambda (event &rest arguments)
              (push (cons event arguments) events))
            (wc:proxy-hooks registry))
      (emit peer (wc:proxy-id registry) 0 :uint 1 :string "wl_compositor" :uint 5)
      (emit peer (wc:proxy-id registry) 0 :uint 2 :string "wl_shm" :uint 1)
      (emit peer (wc:proxy-id registry) 1 :uint 1)
      (dispatch-until display (lambda () (= 3 (length events))))
      (is-equal '((:global 1 "wl_compositor" 5)
                  (:global 2 "wl_shm" 1)
                  (:global-remove 1))
                (nreverse events)))))

(defclass recording-registry (wc:registry) ())

(defvar *global-calls* nil)

(defmethod wayland:wl-registry.global ((registry recording-registry) name interface version)
  (push (list name interface version) *global-calls*))

(deftest event-generic-functions-dispatch
  "A method on the generated event function runs without any hook installed."
  (with-display (display peer)
    (let ((*global-calls* nil))
      (wc:register-proxy display 2 "wl_registry" :class 'recording-registry)
      (emit peer 2 0 :uint 7 :string "wl_output" :uint 4)
      (dispatch-until display (lambda () *global-calls*) :timeout 2)
      (is-equal '((7 "wl_output" 4)) *global-calls*))))

(deftest events-carry-server-allocated-ids
  "wl_data_device.data_offer introduces an object the *server* named."
  (with-display (display peer)
    (wc:register-proxy display 2 "wl_data_device")
    (let ((offers '()))
      (push (lambda (event &rest arguments)
              (push (cons event arguments) offers))
            (wc:proxy-hooks (wc:object-for-id display 2)))
      ;; data_offer(id :new-id "wl_data_offer") at opcode 0.
      (emit peer 2 0 :new-id 9)
      (dispatch-until display (lambda () offers))
      (let ((offer (wc:object-for-id display 9)))
        (is (typep offer 'wc:proxy))
        (is-equal "wl_data_offer" (wp:interface-name (wc:proxy-interface offer)))
        (is-equal 1 (length offers))
        (is (eq offer (second (first offers))) "the hook sees the proxy, not the id")))))

(deftest delete-id-frees-the-id-for-reuse
  (with-display (display peer)
    (let ((registry (wc:wl-display.get-registry display)))
      (is-equal 2 (wc:proxy-id registry))
      (emit peer 1 1 :uint 2)               ; wl_display.delete_id(2)
      (dispatch-until display (lambda () (null (wc:object-for-id display 2))))
      (is (null (wc:object-for-id display 2)))
      (is (wc:proxy-destroyed-p registry))
      (is-equal 2 (wc:proxy-id (wc:wl-display.get-registry display))
                :description "the id came back into circulation"))))

(deftest display-error-is-a-condition
  (with-display (display peer)
    (let ((signalled nil))
      (emit peer 1 0 :object 2 :uint 3 :string "bad object")
      (handler-case (wc:dispatch display :timeout 2)
        (wc:display-error (condition)
          (setf signalled condition)))
      (is (typep signalled 'wc:display-error))
      (is-equal 3 (wc:display-error-code signalled))
      (is-equal "bad object" (wc:display-error-message signalled)))))

(deftest events-for-unknown-objects-are-refused
  (with-display (display peer)
    (emit peer 99 0 :uint 1)
    (signals wc:unknown-object (wc:dispatch display :timeout 2))))

(deftest a-partial-message-waits-for-its-tail
  (with-display (display peer)
    (let* ((registry (wc:wl-display.get-registry display))
           (events '()))
      (push (lambda (event &rest arguments)
              (push (cons event arguments) events))
            (wc:proxy-hooks registry))
      (let* ((buffer (encode-message (wc:proxy-id registry) 0
                                     '(:uint 1 :string "wl_shm" :uint 1)))
             (octets (wire:buffer-contents buffer))
             (size (length octets)))
        (ffi:send-with-ancillary peer octets 0 6 '())
        (wc:dispatch display :timeout 0.1)
        (is (null events) "a truncated message is not dispatched")
        (ffi:send-with-ancillary peer octets 6 size '())
        (dispatch-until display (lambda () events))
        (is-equal '((:global 1 "wl_shm" 1)) events)))))

;;; ---------------------------------------------------------------------------
;;; Roundtrips
;;; ---------------------------------------------------------------------------

(deftest roundtrip-returns-after-done
  (with-display (display peer)
    (let ((registry (wc:wl-display.get-registry display)))
      (emit peer (wc:proxy-id registry) 0 :uint 1 :string "wl_compositor" :uint 5)
      ;; The sync allocates the next id, so its done event names that id.
      (emit peer 3 0 :uint 0)
      (is (wc:roundtrip display :timeout 2)))))

(deftest roundtrip-times-out
  (with-display (display peer)
    (signals wc:roundtrip-timeout (wc:roundtrip display :timeout 0.05))))

(deftest roundtrip-propagates-display-errors
  (with-display (display peer)
    (emit peer 1 0 :object 1 :uint 4 :string "implementation error")
    (signals wc:display-error (wc:roundtrip display :timeout 2))))

;;; ---------------------------------------------------------------------------
;;; Lifetime
;;; ---------------------------------------------------------------------------

(deftest disconnect-closes-and-is-idempotent
  (multiple-value-bind (client peer) (ffi:make-socket-pair)
    (let ((display (wc:make-display-from-fd client)))
      (is (ffi:fd-open-p client))
      (is (wc:disconnect display))
      (is (not (ffi:fd-open-p client)))
      (is (wc:display-closed-p display))
      (is (wc:disconnect display) "second call is a no-op")
      (ffi:close-fd peer))))

(deftest requests-on-destroyed-objects-signal
  (with-display (display peer)
    (let ((registry (wc:wl-display.get-registry display)))
      (emit peer 1 1 :uint 2)               ; delete_id for the registry
      (dispatch-until display (lambda () (null (wc:object-for-id display 2))))
      (signals wc:destroyed-proxy
        (wc:wl-registry.bind registry 1 "wl_compositor" 1))
      (is (null (wc:object-for-id display 3))
          "no proxy was leaked by the failed bind"))))

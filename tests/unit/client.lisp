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
  (:use #:cl #:rove)
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
      (ok (not truncated-p) "no descriptor truncation expected in these tests")
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
  (ok (equal "/run/user/1000/wayland-0"
            (wc:socket-path :display-name "wayland-0" :runtime-dir "/run/user/1000")))
  (ok (equal "/tmp/nested-wayland"
            (wc:socket-path :display-name "/tmp/nested-wayland" :runtime-dir "/run/user/1000")))
  (ok (equal "/run/user/1000/wayland-7"
            (wc:socket-path :display-name "wayland-7" :runtime-dir "/run/user/1000/")))
  ;; The bare default, independent of this machine's WAYLAND_DISPLAY; then the
  ;; environment value, passed in explicitly so the test owns it.
  (ok (equal "wayland-0"
             (pathname-name (pathname (wc:socket-path :display-name nil
                                                      :wayland-display nil
                                                      :runtime-dir "/run/user/1000")))))
  (ok (equal "/run/user/1000/wayland-9"
             (wc:socket-path :display-name nil
                             :wayland-display "wayland-9"
                             :runtime-dir "/run/user/1000")))
  (ok (plusp (length (wc:socket-path :wayland-display "wayland-0"
                                    :runtime-dir "/run/user/1000"))))
  (ok (signals (wc:socket-path :display-name "wayland-0" :runtime-dir nil) 'wc:client-error))
  (ok (signals (wc:socket-path :display-name "" :runtime-dir "/run/user/1000") 'wc:client-error)))

(deftest connect-reports-a-missing-socket
  (ok (signals (wc:connect :path "/nonexistent-wayland-directory/wayland-0")
               'wc:connection-failed)))

;;; ---------------------------------------------------------------------------
;;; Requests
;;; ---------------------------------------------------------------------------

(deftest get-registry-sends-display-request
  (with-display (display peer)
    (let ((registry (wc:wl-display.get-registry display)))
      (ok (equal "wl_registry" (wp:interface-name (wc:proxy-interface registry))))
      (ok (equal wc:+first-client-id+ (wc:proxy-id registry)))
      (ok (eq registry (wc:object-for-id display (wc:proxy-id registry))))
      (ok (wc:flush display))
      (let ((messages (read-messages peer)))
        (ok (equal 1 (length messages)))
        (destructuring-bind (object-id opcode reader) (first messages)
          (ok (equal 1 object-id) "the request goes to wl_display")
          (ok (equal 1 opcode) "wl_display.get_registry")
          (ok (equal (wc:proxy-id registry) (wire:read-uint reader)) "new id")
          (ok (wire:reader-done-p reader)))))))

(deftest ids-are-allocated-in-order
  (with-display (display peer)
    (let ((first (wc:wl-display.get-registry display))
          (second (wc:wl-display.get-registry display))
          (callback (wc:wl-display.sync display)))
      (ok (equal '(2 3 4) (list (wc:proxy-id first) (wc:proxy-id second)
                               (wc:proxy-id callback)))))))

(deftest requests-not-sent-until-flushed
  (with-display (display peer)
    (wc:wl-display.get-registry display)
    (ok (plusp (wire:buffer-size (wc:display-output display)))
        "the request is encoded into the out buffer")
    (ok (zerop (length (read-message peer)))
        "and nothing has reached the socket yet")
    (wc:flush display)
    (ok (plusp (length (read-message peer))))))

(deftest bind-encodes-the-four-wire-arguments
  (with-display (display peer)
    (let* ((registry (wc:wl-display.get-registry display))
           (compositor (wc:wl-registry.bind registry 5 "wl_compositor" 3)))
      (ok (equal "wl_compositor" (wp:interface-name (wc:proxy-interface compositor))))
      (ok (equal 3 (wc:proxy-version compositor)))
      (wc:flush display)
      (let ((messages (read-messages peer)))
        (ok (equal 2 (length messages)) "get_registry and bind")
        (destructuring-bind (object-id opcode reader) (second messages)
          (ok (equal (wc:proxy-id registry) object-id))
          (ok (equal 0 opcode) "wl_registry.bind")
          (ok (equal 5 (wire:read-uint reader)) "name")
          (ok (equal "wl_compositor" (wire:read-string reader)) "interface")
          (ok (equal 3 (wire:read-uint reader)) "version")
          (ok (equal (wc:proxy-id compositor) (wire:read-uint reader)) "id")
          (ok (wire:reader-done-p reader)))))))

(deftest bind-clamps-the-version-to-the-interface
  (with-display (display peer)
    (let* ((registry (wc:wl-display.get-registry display))
           (interface (wp:find-interface "wl_compositor"))
           (bound (wc:wl-registry.bind registry 5 "wl_compositor" 999)))
      (ok (equal (wp:interface-version interface) (wc:proxy-version bound)))
      (ok (signals (wc:wl-registry.bind registry 6 "wl_compositor" 0) 'wc:client-error)))))

(deftest bind-refuses-an-unknown-interface
  (with-display (display peer)
    (let ((registry (wc:wl-display.get-registry display)))
      (ok (signals (wc:wl-registry.bind registry 1 "not_a_protocol_yet" 1) 'wp:invalid-schema)))))

(deftest argument-checks-follow-the-xml
  (with-display (display peer)
    (let ((source (wc:register-proxy display 4 "wl_data_source"))
          (subsurface (wc:register-proxy display 5 "wl_subsurface")))
      ;; offer(mime_type :string) is not nullable.
      (ok (signals (wc:send-request source
                                    (wc:interface-request "wl_data_source" 0) nil)
                   'wc:client-error))
      ;; place_above(sibling :object) is not nullable either.
      (ok (signals (wc:send-request subsurface
                                    (wc:interface-request "wl_subsurface" 2) nil)
                   'wc:client-error))
      ;; Wrong arity is a caller bug, caught rather than silently encoded.
      (ok (signals (wc:send-request source
                                    (wc:interface-request "wl_data_source" 0)
                                    "text/plain" 1)
                   'wc:client-error)))))

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
      (ok (equal '((:global 1 "wl_compositor" 5)
                  (:global 2 "wl_shm" 1)
                  (:global-remove 1))
                (nreverse events))))))

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
      (ok (equal '((7 "wl_output" 4)) *global-calls*)))))

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
        (ok (typep offer 'wc:proxy))
        (ok (equal "wl_data_offer" (wp:interface-name (wc:proxy-interface offer))))
        (ok (equal 1 (length offers)))
        (ok (eq offer (second (first offers))) "the hook sees the proxy, not the id")))))

(deftest delete-id-frees-the-id-for-reuse
  (with-display (display peer)
    (let ((registry (wc:wl-display.get-registry display)))
      (ok (equal 2 (wc:proxy-id registry)))
      (emit peer 1 1 :uint 2)               ; wl_display.delete_id(2)
      (dispatch-until display (lambda () (null (wc:object-for-id display 2))))
      (ok (null (wc:object-for-id display 2)))
      (ok (wc:proxy-destroyed-p registry))
      (ok (equal 2 (wc:proxy-id (wc:wl-display.get-registry display)))
          "the id came back into circulation"))))

(deftest display-error-is-a-condition
  (with-display (display peer)
    (let ((signalled nil))
      (emit peer 1 0 :object 2 :uint 3 :string "bad object")
      (handler-case (wc:dispatch display :timeout 2)
        (wc:display-error (condition)
          (setf signalled condition)))
      (ok (typep signalled 'wc:display-error))
      (ok (equal 3 (wc:display-error-code signalled)))
      (ok (equal "bad object" (wc:display-error-message signalled))))))

(deftest events-for-unknown-objects-are-refused
  (with-display (display peer)
    (emit peer 99 0 :uint 1)
    (ok (signals (wc:dispatch display :timeout 2) 'wc:unknown-object))))

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
        (ok (null events) "a truncated message is not dispatched")
        (ffi:send-with-ancillary peer octets 6 size '())
        (dispatch-until display (lambda () events))
        (ok (equal '((:global 1 "wl_shm" 1)) events))))))

;;; ---------------------------------------------------------------------------
;;; Roundtrips
;;; ---------------------------------------------------------------------------

(deftest roundtrip-returns-after-done
  (with-display (display peer)
    (let ((registry (wc:wl-display.get-registry display)))
      (emit peer (wc:proxy-id registry) 0 :uint 1 :string "wl_compositor" :uint 5)
      ;; The sync allocates the next id, so its done event names that id.
      (emit peer 3 0 :uint 0)
      (ok (wc:roundtrip display :timeout 2)))))

(deftest roundtrip-times-out
  (with-display (display peer)
    (ok (signals (wc:roundtrip display :timeout 0.05) 'wc:roundtrip-timeout))))

(deftest roundtrip-propagates-display-errors
  (with-display (display peer)
    (emit peer 1 0 :object 1 :uint 4 :string "implementation error")
    (ok (signals (wc:roundtrip display :timeout 2) 'wc:display-error))))

;;; ---------------------------------------------------------------------------
;;; Lifetime
;;; ---------------------------------------------------------------------------

(deftest disconnect-closes-and-is-idempotent
  (multiple-value-bind (client peer) (ffi:make-socket-pair)
    (let ((display (wc:make-display-from-fd client)))
      (ok (ffi:fd-open-p client))
      (ok (wc:disconnect display))
      (ok (not (ffi:fd-open-p client)))
      (ok (wc:display-closed-p display))
      (ok (wc:disconnect display) "second call is a no-op")
      (ffi:close-fd peer))))

(deftest requests-on-destroyed-objects-signal
  (with-display (display peer)
    (let ((registry (wc:wl-display.get-registry display)))
      (emit peer 1 1 :uint 2)               ; delete_id for the registry
      (dispatch-until display (lambda () (null (wc:object-for-id display 2))))
      (ok (signals (wc:wl-registry.bind registry 1 "wl_compositor" 1) 'wc:destroyed-proxy))
      (ok (null (wc:object-for-id display 3))
          "no proxy was leaked by the failed bind"))))

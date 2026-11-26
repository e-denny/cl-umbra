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

;;; ---------------------------------------------------------------------------
;;; Surfaces, regions and buffers (phase 3, nested backend)
;;; ---------------------------------------------------------------------------
;;
;; These tests are wire-level on purpose: the compositor half of the same schema is
;; already covered by wayland.test.server, so what is worth pinning here is that the
;; *client* puts the right opcode, id and arguments in the right order -- and, for
;; shm, that the descriptor really travels.

(defun receive-message-with-fds (fd &key (size 4096))
  "The octets and the descriptors the client wrote; the caller closes the fds."
  (let ((octets (make-array size :element-type '(unsigned-byte 8))))
    (multiple-value-bind (count fds truncated-p eof-p)
        (ffi:receive-with-ancillary fd octets 0 size :fds-max 8)
      (declare (ignore eof-p))
      (ok (not truncated-p))
      (values (subseq octets 0 count) fds))))

(deftest create-surface-and-region-are-client-requests
  (with-display (display peer)
    (let* ((registry (wc:wl-display.get-registry display))
           (compositor (wc:wl-registry.bind registry 1 "wl_compositor" 3))
           (surface (wc:wl-compositor.create-surface compositor))
           (region (wc:wl-compositor.create-region compositor)))
      (ok (typep surface 'wc:surface))
      (ok (typep region 'wc:region))
      (ok (equal 3 (wc:proxy-version surface)) "a surface speaks the compositor's version")
      (wc:flush display)
      (let ((messages (read-messages peer)))
        ;; get_registry, bind, create_surface, create_region
        (ok (equal 4 (length messages)))
        (destructuring-bind (object-id opcode reader) (third messages)
          (ok (equal (wc:proxy-id compositor) object-id))
          (ok (equal 0 opcode) "wl_compositor.create_surface")
          (ok (equal (wc:proxy-id surface) (wire:read-uint reader)))
          (ok (wire:reader-done-p reader)))
        (destructuring-bind (object-id opcode reader) (fourth messages)
          (ok (equal (wc:proxy-id compositor) object-id))
          (ok (equal 1 opcode) "wl_compositor.create_region")
          (ok (equal (wc:proxy-id region) (wire:read-uint reader)))
          (ok (wire:reader-done-p reader)))))))

(deftest surface-state-requests-encode-their-arguments
  (with-display (display peer)
    (let* ((registry (wc:wl-display.get-registry display))
           (compositor (wc:wl-registry.bind registry 1 "wl_compositor" 3))
           (surface (wc:wl-compositor.create-surface compositor))
           (buffer (wc:register-proxy display 20 "wl_buffer"))
           (callback (wc:wl-surface.frame surface)))
      (ok (typep callback 'wc:callback))
      (wc:wl-surface.attach surface buffer 10 20)
      (wc:wl-surface.damage surface 0 0 64 32)
      (wc:wl-surface.set-input-region surface nil)
      (wc:wl-surface.set-buffer-scale surface 2)
      (wc:wl-surface.commit surface)
      (wc:flush display)
      (let ((messages (read-messages peer)))
        ;; get_registry, bind, create_surface, then everything above.
        (ok (equal 9 (length messages)))
        (destructuring-bind (object-id opcode reader) (nth 3 messages)
          (ok (equal (wc:proxy-id surface) object-id))
          (ok (equal 3 opcode) "wl_surface.frame")
          (ok (equal (wc:proxy-id callback) (wire:read-uint reader))))
        (destructuring-bind (object-id opcode reader) (nth 4 messages)
          (ok (equal (wc:proxy-id surface) object-id))
          (ok (equal 1 opcode) "wl_surface.attach")
          (ok (equal (wc:proxy-id buffer) (wire:read-uint reader)) "the buffer id")
          (ok (equal 10 (wire:read-int reader)))
          (ok (equal 20 (wire:read-int reader)))
          (ok (wire:reader-done-p reader)))
        (destructuring-bind (object-id opcode reader) (nth 5 messages)
          (ok (equal (wc:proxy-id surface) object-id))
          (ok (equal 2 opcode) "wl_surface.damage")
          (ok (equal '(0 0 64 32)
                     (list (wire:read-int reader) (wire:read-int reader)
                           (wire:read-int reader) (wire:read-int reader))))
          (ok (wire:reader-done-p reader)))
        (destructuring-bind (object-id opcode reader) (nth 6 messages)
          (ok (equal (wc:proxy-id surface) object-id))
          (ok (equal 5 opcode) "wl_surface.set_input_region")
          (ok (equal 0 (wire:read-uint reader)) "NIL is a null id, not a missing argument")
          (ok (wire:reader-done-p reader)))
        (destructuring-bind (object-id opcode reader) (nth 7 messages)
          (ok (equal (wc:proxy-id surface) object-id))
          (ok (equal 8 opcode) "wl_surface.set_buffer_scale")
          (ok (equal 2 (wire:read-int reader))))
        (destructuring-bind (object-id opcode reader) (first (last messages))
          (ok (equal (wc:proxy-id surface) object-id))
          (ok (equal 6 opcode) "wl_surface.commit")
          (ok (wire:reader-done-p reader)))))))

(deftest shm-pool-sends-its-descriptor
  "The descriptor is the whole point of wl_shm: it must arrive as ancillary data,
with the size on the wire and no octets spent on the fd itself (D23)."
  (with-display (display peer)
    (let* ((registry (wc:wl-display.get-registry display))
           (shm (wc:wl-registry.bind registry 1 "wl_shm" 1))
           (size (* 8 8 4))
           (pool (wc:make-client-pool shm size)))
      (ok (typep (wc:client-pool-proxy pool) 'wc:shm-pool))
      (wc:flush display)
      ;; get_registry, bind, create_pool
      (multiple-value-bind (octets fds) (receive-message-with-fds peer)
        (unwind-protect
             (progn
               (ok (equal 1 (length fds)) "exactly one descriptor")
               (let ((messages '())
                     (start 0))
                 (loop
                   (multiple-value-bind (object-id opcode message-size)
                       (wire:decode-header octets :start start)
                     (unless (and object-id (<= (+ start message-size) (length octets)))
                       (return))
                     (push (list object-id opcode
                                 (wire:make-reader octets
                                                   :start (+ start wire:+header-size+)
                                                   :end (+ start message-size)))
                           messages)
                     (incf start message-size)))
                 (ok (equal 3 (length messages)))
                 (destructuring-bind (object-id opcode reader) (third (nreverse messages))
                   (ok (equal (wc:proxy-id shm) object-id))
                   (ok (equal 0 opcode) "wl_shm.create_pool")
                   (ok (equal (wc:proxy-id (wc:client-pool-proxy pool))
                              (wire:read-uint reader)))
                   (ok (equal size (wire:read-int reader)) "the size, and nothing for the fd")
                   (ok (wire:reader-done-p reader))))
               ;; The descriptor the compositor received names the same file as our
               ;; mapping: write through one, read through the other.
               (let ((pointer (ffi:map-file (first fds) size
                                            :protection ffi:+prot-read+)))
                 (unwind-protect
                      (progn
                        (setf (wc:client-buffer-pixel
                               (wc:allocate-client-buffer pool :width 8 :height 8)
                               3 2)
                              #xFF112233))
                      (ffi:unmap-file pointer size))))
             (dolist (fd fds) (ffi:close-fd fd)))))))

(deftest client-buffer-pixels-and-bounds
  (with-display (display peer)
    (let* ((registry (wc:wl-display.get-registry display))
           (shm (wc:wl-registry.bind registry 1 "wl_shm" 1))
           (pool (wc:make-client-pool shm (* 16 16 4)))
           (buffer (wc:allocate-client-buffer pool :width 16 :height 16)))
      (ok (equal 16 (wc:client-buffer-width buffer)))
      (ok (equal 64 (wc:client-buffer-stride buffer)))
      (setf (wc:client-buffer-pixel buffer 3 4) #xFF00FF00)
      (ok (equal #xFF00FF00 (wc:client-buffer-pixel buffer 3 4)))
      (wc:client-buffer-fill buffer #xFF102030)
      (ok (equal #xFF102030 (wc:client-buffer-pixel buffer 15 15)))
      (wc:client-buffer-fill-rect buffer -4 -4 8 8 #xFFAABBCC)
      (ok (equal #xFFAABBCC (wc:client-buffer-pixel buffer 0 0))
          "a fill rectangle is clipped, not an error")
      (ok (equal #xFF102030 (wc:client-buffer-pixel buffer 5 5)))
      (ok (signals (wc:client-buffer-pixel buffer 16 0) 'wc:client-error))
      (ok (signals (wc:allocate-client-buffer pool :width 64 :height 64) 'wc:client-error)
          "a buffer larger than its pool is refused before anything is written")
      (ok (signals (wc:allocate-client-buffer pool :width 8 :height 8 :stride 16)
                   'wc:client-error)
          "a stride smaller than width*4 is refused")
      (ok (signals (wc:allocate-client-buffer pool :width 8 :height 8 :stride 30)
                   'wc:client-error)
          "a stride that is not a multiple of four is refused"))))

(deftest attach-accepts-a-client-buffer
  "ATTACH takes the CLIENT-BUFFER struct; the encoder asks it for its wl_buffer id."
  (with-display (display peer)
    (let* ((registry (wc:wl-display.get-registry display))
           (compositor (wc:wl-registry.bind registry 1 "wl_compositor" 3))
           (shm (wc:wl-registry.bind registry 2 "wl_shm" 1))
           (surface (wc:wl-compositor.create-surface compositor))
           (pool (wc:make-client-pool shm 64))
           (buffer (wc:allocate-client-buffer pool :width 4 :height 4)))
      (wc:wl-surface.attach surface buffer 0 0)
      (ok (equal (wc:proxy-id (wc:client-buffer-proxy buffer))
                 (wc:object-id-of buffer)))
      (wc:flush display)
      (ok (plusp (length (read-message peer)))))))

(deftest seat-device-factories
  (with-display (display peer)
    (let* ((registry (wc:wl-display.get-registry display))
           (seat (wc:wl-registry.bind registry 1 "wl_seat" 4))
           (pointer (wc:wl-seat.get-pointer seat))
           (keyboard (wc:wl-seat.get-keyboard seat))
           (touch (wc:wl-seat.get-touch seat)))
      (ok (typep pointer 'wc:pointer))
      (ok (typep keyboard 'wc:keyboard))
      (ok (typep touch 'wc:touch))
      (wc:wl-pointer.set-cursor pointer 7 nil 0 0)
      (wc:wl-seat.release seat)
      (wc:flush display)
      (let ((messages (read-messages peer)))
        (destructuring-bind (object-id opcode reader) (third messages)
          (ok (equal (wc:proxy-id seat) object-id))
          (ok (equal 0 opcode) "wl_seat.get_pointer")
          (ok (equal (wc:proxy-id pointer) (wire:read-uint reader))))
        (destructuring-bind (object-id opcode reader) (nth 3 messages)
          (ok (equal (wc:proxy-id seat) object-id))
          (ok (equal 1 opcode) "wl_seat.get_keyboard")
          (ok (equal (wc:proxy-id keyboard) (wire:read-uint reader))))
        (destructuring-bind (object-id opcode reader) (nth 4 messages)
          (ok (equal (wc:proxy-id seat) object-id))
          (ok (equal 2 opcode) "wl_seat.get_touch")
          (ok (equal (wc:proxy-id touch) (wire:read-uint reader))))
        (destructuring-bind (object-id opcode reader) (nth 5 messages)
          (ok (equal (wc:proxy-id pointer) object-id))
          (ok (equal 0 opcode) "wl_pointer.set_cursor")
          (ok (equal 7 (wire:read-uint reader)) "serial")
          (ok (equal 0 (wire:read-uint reader)) "a null surface")
          (ok (equal 0 (wire:read-int reader)))
          (ok (equal 0 (wire:read-int reader))))
        (destructuring-bind (object-id opcode reader) (first (last messages))
          (ok (equal (wc:proxy-id seat) object-id))
          (ok (equal 3 opcode) "wl_seat.release")
          (ok (wire:reader-done-p reader)))))))

(deftest xdg-shell-client-handshake
  (with-display (display peer)
    (let* ((registry (wc:wl-display.get-registry display))
           (compositor (wc:wl-registry.bind registry 1 "wl_compositor" 3))
           (wm-base (wc:wl-registry.bind registry 2 "xdg_wm_base" 1))
           (surface (wc:wl-compositor.create-surface compositor))
           (shell (wc:xdg-wm-base.get-xdg-surface wm-base surface))
           (toplevel (wc:xdg-surface.get-toplevel shell)))
      (ok (typep shell 'wc:xdg-surface))
      (ok (typep toplevel 'wc:xdg-toplevel))
      (wc:xdg-toplevel.set-title toplevel "hello")
      (wc:xdg-toplevel.set-app-id toplevel "test")
      (wc:xdg-surface.ack-configure shell 99)
      (wc:xdg-surface.set-window-geometry shell 0 0 100 50)
      (wc:flush display)
      (let ((messages (read-messages peer)))
        ;; get_registry, bind compositor, bind wm_base, create_surface, then the
        ;; handshake.
        (ok (equal 10 (length messages)))
        (destructuring-bind (object-id opcode reader) (nth 4 messages)
          (ok (equal (wc:proxy-id wm-base) object-id))
          (ok (equal 2 opcode) "xdg_wm_base.get_xdg_surface")
          (ok (equal (wc:proxy-id shell) (wire:read-uint reader)))
          (ok (equal (wc:proxy-id surface) (wire:read-uint reader)) "the role holder"))
        (destructuring-bind (object-id opcode reader) (nth 5 messages)
          (ok (equal (wc:proxy-id shell) object-id))
          (ok (equal 1 opcode) "xdg_surface.get_toplevel")
          (ok (equal (wc:proxy-id toplevel) (wire:read-uint reader))))
        (destructuring-bind (object-id opcode reader) (nth 6 messages)
          (ok (equal (wc:proxy-id toplevel) object-id))
          (ok (equal 2 opcode) "xdg_toplevel.set_title")
          (ok (equal "hello" (wire:read-string reader))))
        (destructuring-bind (object-id opcode reader) (nth 7 messages)
          (ok (equal (wc:proxy-id toplevel) object-id))
          (ok (equal 3 opcode) "xdg_toplevel.set_app_id")
          (ok (equal "test" (wire:read-string reader))))
        (destructuring-bind (object-id opcode reader) (nth 8 messages)
          (ok (equal (wc:proxy-id shell) object-id))
          (ok (equal 4 opcode) "xdg_surface.ack_configure")
          (ok (equal 99 (wire:read-uint reader))))
        (destructuring-bind (object-id opcode reader) (nth 9 messages)
          (ok (equal (wc:proxy-id shell) object-id))
          (ok (equal 3 opcode) "xdg_surface.set_window_geometry")
          (ok (equal '(0 0 100 50)
                     (list (wire:read-int reader) (wire:read-int reader)
                           (wire:read-int reader) (wire:read-int reader))))
          (ok (wire:reader-done-p reader)))))))

(deftest ping-is-answered-with-pong
  "xdg_wm_base.ping is a liveness check: a client that does not answer can be killed
as unresponsive, so the answer is not policy and lives in the library."
  (with-display (display peer)
    (let* ((registry (wc:wl-display.get-registry display))
           (wm-base (wc:wl-registry.bind registry 1 "xdg_wm_base" 1)))
      (ok (typep wm-base 'wc:xdg-wm-base))
      (wc:flush display)
      (multiple-value-bind (octets fds) (receive-message-with-fds peer)
        (declare (ignore octets))
        (dolist (fd fds) (ffi:close-fd fd)))
      (emit peer (wc:proxy-id wm-base) 0 :uint 4242)   ; ping(serial)
      ;; One dispatch handles the ping; the pong is queued in the out buffer and
      ;; needs the flush a real client does every cycle (D27).
      (wc:dispatch display :timeout 2)
      (wc:flush display)
      (let ((messages (read-messages peer)))
        (ok (equal 1 (length messages)))
        (destructuring-bind (object-id opcode reader) (first messages)
          (ok (equal (wc:proxy-id wm-base) object-id))
          (ok (equal 3 opcode) "xdg_wm_base.pong")
          (ok (equal 4242 (wire:read-uint reader)))
          (ok (wire:reader-done-p reader)))))))

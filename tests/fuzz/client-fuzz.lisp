;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The peer fuzzer: a client that talks nonsense to our server.
;;;;
;;;; The decoder fuzzer (`fuzz.lisp`) proves that garbage in the *transport* is
;;;; either decoded or rejected.  This one puts the garbage on a real connection
;;;; and asks a different question: can a client make the server crash, wedge,
;;;; leak, or answer with a malformed message?  The invariants, per case:
;;;;
;;;;   1. whatever the reply is, it is well-formed framing, and at most one
;;;;      wl_display.error, on wl_display;
;;;;   2. after the client goes away, the server has dropped it -- no wedge;
;;;;   3. nothing the client did made *our* code signal a Lisp error.  Client
;;;;      faults become protocol errors; an internal error is a bug, and it is
;;;;      detected by capturing the server's :error log for the whole run;
;;;;   4. across the run: no descriptor leak, no runaway memory, and the server
;;;;      still serves a well-behaved client afterwards.
;;;;
;;;; Every case is one connection.  That is the expensive part and it is the
;;;; point: accept, credentials, id allocation and teardown are in the path.

(in-package #:cl-user)

(defpackage #:wayland.fuzz.client
  (:use #:cl)
  (:local-nicknames (#:srv #:wayland.server)
                    (#:wire #:wayland.wire)
                    (#:io #:wayland.io)
                    (#:ffi #:wayland.ffi)
                    (#:wp #:wayland.protocol))
  (:import-from #:wayland.fuzz.rng
                #:make-seeded-rng
                #:rng-next
                #:rng-below
                #:rng-octets
                #:random-choice
                #:store-u32)
  (:documentation
   "The peer fuzzer: random and adversarial clients against a live display
(docs/testing.md §4).  One connection per case; the server must survive all of
them and keep serving well-behaved clients.")
  (:export #:run #:main #:+default-iterations+))

(in-package #:wayland.fuzz.client)

(defconstant +default-iterations+ 1000000)

;;; ---------------------------------------------------------------------------
;;; Findings
;;; ---------------------------------------------------------------------------

(define-condition client-fuzz-failure (error)
  ((iteration :initarg :iteration :reader failure-iteration)
   (detail :initarg :detail :reader failure-detail)
   (octets :initarg :octets :initform nil :reader failure-octets))
  (:report (lambda (condition stream)
             (format stream "client fuzz failure at iteration ~D: ~A~@[~%  wrote: ~{~2,'0X~}~]"
                     (failure-iteration condition)
                     (failure-detail condition)
                     (failure-octets condition)))))

(defun fail (iteration detail &optional octets)
  (error 'client-fuzz-failure :iteration iteration :detail detail :octets octets))

;;; ---------------------------------------------------------------------------
;;; Encoding
;;; ---------------------------------------------------------------------------

(defun buffer-octets (buffer)
  (subseq (wire:buffer-octets buffer) 0 (wire:buffer-size buffer)))

(defun encode (object-id opcode &optional writer)
  (let* ((buffer (wire:make-message-buffer))
         (start (wire:begin-message buffer object-id opcode)))
    (when writer (funcall writer buffer))
    (wire:end-message buffer start)
    (buffer-octets buffer)))

(defun concat-octets (&rest pieces)
  (let* ((length (reduce #'+ pieces :key #'length :initial-value 0))
         (result (make-array length :element-type '(unsigned-byte 8)))
         (offset 0))
    (dolist (piece pieces result)
      (replace result piece :start1 offset)
      (incf offset (length piece)))))

(defun random-target-id (rng)
  "The object a message is addressed to: the ones that exist, and ones that do not.

Never 0: the wire has no message addressed to the null object, so a 0 here would
be a fuzzer bug rather than a protocol violation."
  (case (rng-below rng 6)
    (0 1)                                   ; wl_display
    (1 2)                                   ; a plausible first client id
    (2 3)
    (3 (1+ (rng-below rng 16)))             ; small, usually unused
    (4 #xFF000001)                          ; server range: never a client's
    (t (1+ (rng-below rng #xFFFFFFFE)))))

(defun random-object-id (rng)
  "An argument that names an object: a target id, or NIL for the null object.

NIL, not 0: the wire writes an id of 0 for null, but the encoder takes the null
object as NIL and refuses an actual 0, so a caller cannot confuse the two."
  (if (zerop (rng-below rng 5))
      nil
      (random-target-id rng)))

(defun random-new-id (rng)
  "An id a client might supply for a new_id: plausible, reserved, or impossible."
  (case (rng-below rng 5)
    (0 1)                                   ; wl_display, never a new id
    (1 (1+ (rng-below rng 8)))
    (2 #xFF000001)                          ; the server's range
    (3 #xFFFFFFFF)
    (t (1+ (rng-below rng #xFFFFFFFE)))))

(defun random-argument (rng buffer spec)
  "A value for SPEC, mostly type-correct: the point is the protocol, not the codec."
  (ecase (wp:arg-type spec)
    (:int (wire:put-int buffer (- (rng-below rng 2000) 1000)))
    (:uint (wire:put-uint buffer (rng-below rng #x100000000)))
    (:fixed (wire:put-fixed buffer (/ (rng-below rng 1000) 256)))
    (:string
     (wire:put-string buffer
                      (case (rng-below rng 3)
                        (0 nil)
                        (1 "")
                        (t (make-string (rng-below rng 40)
                                        :initial-element
                                        (code-char (+ 32 (rng-below rng 90))))))))
    (:object (wire:put-object buffer (random-object-id rng)))
    (:new-id (wire:put-new-id buffer (random-new-id rng)))
    (:array (wire:put-array buffer (rng-octets rng (rng-below rng 16))))
    (:fd (wire:put-fd buffer (ffi:memfd-create "cl-wayland-fuzz-client")))))

(defun all-requests ()
  (loop for interface in (wp:registered-interfaces)
        append (remove nil (wp:interface-requests interface))))

(defun random-plausible-message (rng requests)
  "A well-framed message whose meaning is arbitrary: real opcode, random object."
  (let ((request (random-choice rng requests)))
    (let* ((buffer (wire:make-message-buffer))
           (start (wire:begin-message buffer (random-target-id rng)
                                      (wp:message-opcode request))))
      (dolist (spec (wp:message-args request))
        ;; A descriptor written here is ours until the message is flushed, then
        ;; the kernel holds a duplicate; the receiver closes the copy.  Close
        ;; ours in every case, so the fuzzer itself cannot leak.
        (random-argument rng buffer spec))
      (wire:end-message buffer start)
      (prog1 (buffer-octets buffer)
        (dolist (fd (wire:buffer-fds buffer)) (ffi:close-fd fd))))))

;;; ---------------------------------------------------------------------------
;;; The five kinds of client
;;; ---------------------------------------------------------------------------

(defun random-garbage (rng)
  (rng-octets rng (1+ (rng-below rng 400))))

(defun random-plausible (rng requests)
  (let ((pieces (loop repeat (1+ (rng-below rng 4))
                      collect (random-plausible-message rng requests))))
    (let ((stream (apply #'concat-octets pieces)))
      ;; Half the time, cut the client off mid-message.
      (if (zerop (rng-below rng 2))
          (subseq stream 0 (rng-below rng (length stream)))
          stream))))

(defun random-abuse (rng)
  "Well-formed messages that are illegal in one specific way."
  (case (rng-below rng 6)
    ;; sync with a new_id that is already the display, or a server id
    (0 (encode 1 0 (lambda (buffer) (wire:put-new-id buffer (random-new-id rng)))))
    ;; get_registry with an id the client may not choose
    (1 (encode 1 1 (lambda (buffer) (wire:put-new-id buffer (random-new-id rng)))))
    ;; an opcode no interface has
    (2 (encode 1 (+ 2 (rng-below rng 60000)) nil))
    ;; a real registry, then a bind with a name, interface or version that
    ;; cannot be right
    (3 (concat-octets
        (encode 1 1 (lambda (buffer) (wire:put-new-id buffer 2)))
        (encode 2 0 (lambda (buffer)
                      (wire:put-uint buffer (1+ (rng-below rng 4)))
                      (wire:put-string buffer (random-choice rng '("wl_output" "wl_compositor" "wl_nope")))
                      (wire:put-uint buffer (case (rng-below rng 3) (0 0) (1 #xFFFFFFFF) (t (1+ (rng-below rng 9)))))
                      (wire:put-new-id buffer (1+ (rng-below rng 8)))))))
    ;; a message whose size says more than it carries, then EOF: a partial
    ;; message the server must keep, not act on
    (4 (let ((stream (encode 1 1 (lambda (buffer) (wire:put-new-id buffer 2)))))
         (subseq stream 0 (1+ (rng-below rng (1- (length stream)))))))
    ;; a valid message with junk inside its declared size
    (t (let ((stream (encode 1 0 (lambda (buffer) (wire:put-new-id buffer 2)))))
         (concat-octets stream (rng-octets rng 4))))))

(defun random-corrupt-size (rng)
  "A valid message whose size field was edited: the framing layer's edge."
  (let ((stream (encode 1 1 (lambda (buffer) (wire:put-new-id buffer 2))))
        (choice (rng-below rng 5)))
    (let ((size (case choice
                  (0 0)
                  (1 (1- (length stream)))       ; not a multiple of 4
                  (2 #xFFFF)                     ; larger than the message
                  (3 4)                          ; smaller than a header
                  (t (+ (length stream) 4)))))
      (store-u32 stream 4 (logior (ash size 16) 1))
      stream)))

;;; ---------------------------------------------------------------------------
;;; One case
;;; ---------------------------------------------------------------------------

(defun write-once (fd octets)
  "One sendmsg of OCTETS; returns the octets accepted, 0 on EAGAIN."
  (if (zerop (length octets))
      0
      (handler-case (ffi:send-with-ancillary fd octets 0 (length octets) nil)
        (ffi:io-error (condition)
          (declare (ignore condition))
          0))))

(defun read-reply (fd &key (limit 65536))
  "Everything the server wrote before it went quiet, as octets."
  (let ((chunks '())
        (buffer (make-array 8192 :element-type '(unsigned-byte 8))))
    (loop
      (multiple-value-bind (count fds truncated-p eof-p)
          (ffi:receive-with-ancillary fd buffer 0 (length buffer) :fds-max 8)
        (dolist (descriptor fds) (ffi:close-fd descriptor))
        (when truncated-p
          ;; The server never sends descriptors in phase 1; if it ever did and
          ;; they were truncated, that is a finding, not a test failure.
          (return (values (apply #'concat-octets (nreverse chunks)) :truncated)))
        (when (plusp count)
          (push (subseq buffer 0 count) chunks))
        (when (or eof-p (zerop count))
          (return (values (apply #'concat-octets (nreverse chunks)) nil))))
      (when (> (reduce #'+ chunks :key #'length :initial-value 0) limit)
        (return (values (apply #'concat-octets (nreverse chunks)) :too-much))))))

(defun check-reply-framing (iteration octets)
  "Every message the server sends must be well-formed, and an error ends the reply."
  (let ((start 0)
        (errors 0))
    (loop
      (when (= start (length octets))
        (return))
      (multiple-value-bind (object-id opcode size)
          (wire:decode-header octets :start start)
        (unless (and object-id (<= 8 size) (<= (+ start size) (length octets)))
          (fail iteration
                (format nil "malformed reply from the server: object ~S opcode ~S size ~S at ~D of ~D octets"
                        object-id opcode size start (length octets))
                octets))
        (when (and (= object-id 1) (= opcode 0))
          (incf errors))
        (incf start size)))
    (when (> errors 1)
      (fail iteration (format nil "the server sent ~D wl_display.error messages" errors) octets))
    ;; An error reply must be complete: the stream ended above only if every
    ;; message fit, which is the check that the server never writes a truncated
    ;; or oversized message.
    errors))

(defun fuzz-case (display octets iteration)
  "One connection: write OCTETS, let the server react, check the invariants."
  (let ((fd (handler-case
                (ffi:connect-unix-socket (srv:display-socket-path display))
              (ffi:io-error ()
                (fail iteration "the server stopped accepting connections")))))
    (unwind-protect
         (progn
           (write-once fd octets)
           ;; Give the server a few cycles to read, answer, and decide.
           (loop repeat 3 do (srv:run-once display :timeout 0))
           (multiple-value-bind (reply flag) (read-reply fd)
             (when (eq flag :truncated)
               (fail iteration "the server's reply had truncated descriptors" octets))
             (check-reply-framing iteration reply))
           (ffi:close-fd fd)
           ;; The client is gone: the server must have dropped it.  A client
           ;; that stays connected after EOF is a wedge.
           (loop repeat 3
                 until (null (srv:display-clients display))
                 do (srv:run-once display :timeout 0))
           (when (srv:display-clients display)
             (fail iteration "the server kept a client after EOF" octets)))
      (when (ffi:fd-open-p fd) (ffi:close-fd fd)))))

(defun generate (rng requests)
  (case (rng-below rng 5)
    (0 (values (random-garbage rng) :garbage))
    (1 (values (random-plausible rng requests) :plausible))
    (2 (values (random-abuse rng) :abuse))
    (3 (values (random-corrupt-size rng) :size))
    (t (values (rng-octets rng (rng-below rng 33)) :tiny))))

;;; ---------------------------------------------------------------------------
;;; Liveness after the abuse
;;; ---------------------------------------------------------------------------

(defun server-still-serves-p (display)
  "A well-behaved raw client gets its globals and a callback, or the server is wedged.

Pumps the server after closing, so the server-side descriptor is gone by the time
the caller looks at the descriptor count."
  (let ((fd (ffi:connect-unix-socket (srv:display-socket-path display))))
    (unwind-protect
         (let ((request (concat-octets
                         (encode 1 1 (lambda (buffer) (wire:put-new-id buffer 2)))
                         (encode 1 0 (lambda (buffer) (wire:put-new-id buffer 3))))))
           (write-once fd request)
           (loop repeat 5 do (srv:run-once display :timeout 0))
           (multiple-value-bind (reply flag) (read-reply fd)
             (declare (ignore flag))
             (let ((messages 0)
                   (saw-done nil)
                   (saw-delete nil)
                   (start 0))
               (loop
                 (when (= start (length reply)) (return))
                 (multiple-value-bind (object-id opcode size)
                     (wire:decode-header reply :start start)
                   (unless (and object-id (<= (+ start size) (length reply)))
                     (return))
                   (incf messages)
                   (when (and (= object-id 3) (= opcode 0)) (setf saw-done t))
                   (when (and (= object-id 1) (= opcode 1)) (setf saw-delete t))
                   (incf start size)))
               (and (plusp messages) saw-done saw-delete))))
      (ffi:close-fd fd)
      ;; Let the server reap it: a descriptor that is still the server's when we
      ;; count would look exactly like a leak.
      (loop repeat 3 do (srv:run-once display :timeout 0)))))

;;; ---------------------------------------------------------------------------
;;; Running it
;;; ---------------------------------------------------------------------------

(defun call-with-deadline (seconds function)
  "Call FUNCTION; true if it finished within SECONDS, NIL if it hung.

A hang is a fuzz finding, not a reason to wait (same watchdog as the decoder
fuzzer; SBCL-only project, so SB-EXT:WITH-TIMEOUT is the tool)."
  #+sbcl
  (handler-case (progn (sb-ext:with-timeout seconds (funcall function)) t)
    (sb-ext:timeout () nil))
  #-sbcl
  (progn (funcall function) t))

(defun open-fd-count ()
  (length (directory (pathname "/proc/self/fd/*"))))

(defun resident-bytes ()
  (with-open-file (stream "/proc/self/statm")
    (let ((line (read-line stream)))
      (* 4096 (parse-integer line :end (or (position #\Space line) (length line)))))))

(defun run (&key (iterations +default-iterations+) (seed 1)
                 (timeout (max 60 (ceiling iterations 10000)))
                 (stream *standard-output*) (error-stream *error-output*))
  "Run ITERATIONS adversarial connections against one demo display.

Returns true when every invariant held.  The seed is printed first: it is the
whole reproduction recipe."
  (let* ((rng (make-seeded-rng seed))
         (requests (all-requests))
         (directory (format nil "/tmp/cl-wayland-fuzz-client-~D/" (ffi:process-id)))
         (log (make-string-output-stream))
         (display nil)
         (cases 0)
         ;; Cases by kind, for the report: garbage, plausible, abusive, bad
         ;; size, tiny.
         (kinds (list :garbage 0 :plausible 0 :abuse 0 :size 0 :tiny 0))
         (ok t))
    (when (null requests)
      (format error-stream "~&no protocol schemas registered; load cl-wayland-protocols~%")
      (return-from run nil))
    (ensure-directories-exist directory)
    (ffi:chmod-path (string-right-trim "/" directory) #o700)
    (format stream "~&fuzz-client: ~D connections, seed ~D~%" iterations seed)
    (unwind-protect
         (progn
           (setf display (srv:make-demo-display :display-name "fuzz-0"
                                                :runtime-dir directory))
           ;; Client faults are expected and logged at :warn; only :error is
           ;; captured, so the log is exactly "did our own code signal".
           (let ((srv:*log-level* :error)
                 (srv:*log-stream* log)
                 (fds-before (open-fd-count))
                 (rss-before (resident-bytes)))
             (handler-case
                 (let ((finished
                         (call-with-deadline
                          timeout
                          (lambda ()
                            (loop for iteration from 0 below iterations
                                  do (incf cases)
                                     (multiple-value-bind (octets kind)
                                         (generate rng requests)
                                       (incf (getf kinds kind))
                                       (fuzz-case display octets iteration))
                                     ;; Every so often, prove the server still
                                     ;; serves a client that behaves.
                                     (when (zerop (mod (1+ iteration) 1000))
                                       (unless (server-still-serves-p display)
                                         (fail iteration "the server stopped serving well-behaved clients"))))))))
                   (unless finished
                     (setf ok nil)
                     (format error-stream
                             "~&no completion within ~D s (~D of ~D cases); a hang is a finding.~%  seed ~D reproduces it.~%"
                             timeout cases iterations seed)))
               (client-fuzz-failure (condition)
                 (setf ok nil)
                 (format error-stream "~&~A~%  seed ~D reproduces it.~%" condition seed)))
             ;; Invariant 3: no internal error, anywhere in the run.
             (let ((text (get-output-stream-string log)))
               (when (plusp (length text))
                 (setf ok nil)
                 (format error-stream
                         "~&the server signalled an internal error; a client must not be able to do that:~%~A~%  seed ~D reproduces it.~%"
                         text seed)))
             ;; Give the last teardown its cycles before measuring anything.
             (loop repeat 4 do (srv:run-once display :timeout 0))
             ;; Invariant 4a: descriptors.
             (let ((fds-after (open-fd-count)))
               (unless (= fds-before fds-after)
                 (setf ok nil)
                 (format error-stream "~&descriptor leak: ~D open before, ~D after~%"
                         fds-before fds-after)))
             ;; Invariant 4b: memory.  The fuzzer itself allocates per case, so
             ;; this is a generous bound that still catches per-connection growth.
             (let ((growth (- (resident-bytes) rss-before)))
               (when (> growth (* 32 1024 1024))
                 (setf ok nil)
                 (format error-stream "~&resident set grew by ~D KiB over the run~%"
                         (round growth 1024))))
             ;; Invariant 4c: still alive and serving at the end.
             (unless (server-still-serves-p display)
               (setf ok nil)
               (format error-stream "~&the server does not serve a well-behaved client at the end of the run~%"))))
      (when display (srv:close-display display))
      (ignore-errors (uiop:delete-directory-tree (pathname directory) :validate t)))
    (format stream
            "~&~D connection~:P fuzzed: ~D garbage, ~D plausible, ~D abusive, ~D bad-size, ~D tiny~%"
            cases (getf kinds :garbage) (getf kinds :plausible)
            (getf kinds :abuse) (getf kinds :size) (getf kinds :tiny))
    (format stream "~&~:[FAILED~;PASSED~]~%" ok)
    ok))

(defun main ()
  "Entry point for scripts/fuzz-client.sh: ITERATIONS [SEED] on the command line."
  (let* ((arguments (uiop:command-line-arguments))
         (iterations (if arguments
                         (parse-integer (first arguments))
                         +default-iterations+))
         (seed (if (rest arguments)
                   (parse-integer (second arguments))
                   1)))
    (uiop:quit (if (run :iterations iterations :seed seed) 0 1))))

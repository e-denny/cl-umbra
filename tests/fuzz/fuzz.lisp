;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later

(in-package #:cl-user)

(defpackage #:wayland.fuzz
  (:use #:cl)
  (:local-nicknames (#:wire #:wayland.wire)
                    (#:io #:wayland.io)
                    (#:ffi #:wayland.ffi)
                    (#:wp #:wayland.protocol))
  (:import-from #:wayland.protocol
                #:registered-interfaces
                #:interface-requests
                #:interface-events
                #:message-args
                #:arg-type)
  ;; The random source is shared with the client fuzzer (wayland.fuzz.rng): one
  ;; seeded generator, so a seed means the same thing in both harnesses.
  (:import-from #:wayland.fuzz.rng
                #:make-seeded-rng
                #:rng-below
                #:rng-octets
                #:random-choice
                #:store-u32)
  (:documentation
   "The decoder fuzzer (docs/testing.md §4): random octets through the header
decoder, random bodies through real message schemas, and random byte streams
through a real socket pair.  A case either produces values or a WAYLAND.WIRE
condition; anything else is a bug worth stopping for.")
  (:export #:run #:main #:+default-iterations+))

(in-package #:wayland.fuzz)

(defconstant +default-iterations+ 1000000)

;;; ---------------------------------------------------------------------------
;;; The failure report
;;; ---------------------------------------------------------------------------

(define-condition fuzz-failure (error)
  ((case :initarg :case :reader fuzz-failure-case)
   (iteration :initarg :iteration :reader fuzz-failure-iteration)
   (octets :initarg :octets :initform nil :reader fuzz-failure-octets)
   (detail :initarg :detail :reader fuzz-failure-detail))
  (:report
   (lambda (condition stream)
     (format stream "fuzz failure in ~A at iteration ~D: ~A~@[~%  octets: ~{~2,'0X~}~]"
             (fuzz-failure-case condition)
             (fuzz-failure-iteration condition)
             (fuzz-failure-detail condition)
             (fuzz-failure-octets condition)))))

;;; ---------------------------------------------------------------------------
;;; Case 1: the header decoder
;;; ---------------------------------------------------------------------------

(defun check-header-invariants (object-id opcode size)
  (unless (plusp object-id)
    (error "decode-header returned object id 0"))
  (unless (and (integerp opcode) (<= 0 opcode #xFFFF))
    (error "opcode ~S is not a 16-bit unsigned integer" opcode))
  (unless (and (>= size wire:+header-size+)
               (zerop (mod size 4))
               (<= size wire:*max-message-size*))
    (error "size ~S passed the header checks" size)))

(defun fuzz-header (rng iteration)
  "Random octets through DECODE-HEADER; half the time with a plausible header."
  (let* ((length (rng-below rng 41))
         (octets (rng-octets rng length)))
    (when (and (>= length wire:+header-size+) (zerop (rng-below rng 2)))
      ;; A header that is mostly sane, so the checks past the length run: size
      ;; is sometimes aligned and in range, sometimes not; the object id is
      ;; sometimes 0.
      (let ((size (if (zerop (rng-below rng 5))
                      (rng-below rng 80)
                      (* 4 (rng-below rng 40))))
            (object-id (if (zerop (rng-below rng 4)) 0 (1+ (rng-below rng 8))))
            (opcode (rng-below rng #x10000)))
        (store-u32 octets 0 object-id)
        (store-u32 octets 4 (logior (ash size 16) opcode))))
    (handler-case
        (multiple-value-bind (object-id opcode size) (wire:decode-header octets)
          (when object-id
            (handler-case (check-header-invariants object-id opcode size)
              (error (condition)
                (error 'fuzz-failure :case :header :iteration iteration
                                     :octets octets :detail condition)))))
      (wire:wire-error () nil))))

;;; ---------------------------------------------------------------------------
;;; Case 2: argument decoding against real schemas
;;; ---------------------------------------------------------------------------

(defun all-messages ()
  "Every request and event of every registered interface, as a flat list."
  (loop for interface in (wp:registered-interfaces)
        append (remove nil (interface-requests interface))
        append (remove nil (interface-events interface))))

(defun decode-typed (arg reader)
  (ecase (wp:arg-type arg)
    (:int (wire:read-int reader))
    (:uint (wire:read-uint reader))
    (:fixed (wire:read-fixed reader))
    (:string (wire:read-string reader))
    (:object (wire:read-object reader))
    (:new-id (wire:read-uint reader))
    (:array (wire:read-array reader))
    (:fd (wire:read-fd reader))))

(defun fuzz-message-decode (rng messages fds)
  "Random octets decoded as the arguments of a random message.

The body is nonsense on purpose: what is being tested is that a schema-driven
decoder either produces a value or signals a WAYLAND.WIRE condition, never
overruns the buffer and never loops."
  (let* ((message (random-choice rng messages))
         (octets (rng-octets rng (rng-below rng 65)))
         (reader (wire:make-reader octets :fds fds)))
    (handler-case
        (dolist (arg (wp:message-args message))
          (decode-typed arg reader))
      (wire:wire-error () nil))))

;;; ---------------------------------------------------------------------------
;;; Case 3: the transport, over a real socket pair
;;; ---------------------------------------------------------------------------

(defun encode-valid-message (rng)
  "A well-formed message with a random object, opcode and payload."
  (let* ((buffer (wire:make-message-buffer))
         (payload (rng-below rng 8))
         (start (wire:begin-message buffer (1+ (rng-below rng 16))
                                    (rng-below rng 64))))
    (dotimes (index payload)
      (wire:put-uint buffer (rng-below rng #x100000000)))
    (wire:end-message buffer start)
    buffer))

(defun close-pending-fds (input)
  "Close descriptors the stream delivered but no message claimed.

WAYLAND.IO queues descriptors in arrival order and hands them to arguments; a
fuzzer feeding descriptors with bodies that never mention them is exactly the
surplus case the protocol layer is supposed to catch, and a harness must not leak
what it provoked.  RESET-INPUT-BUFFER closes them and returns how many."
  (io:reset-input-buffer input))

(defun fuzz-transport (rng iteration socket writer input state fds)
  "One random write to WRITER, then PUMP SOCKET.  STATE tracks what has been seen."
  (let* ((buffer
           (case (rng-below rng 5)
             (0 (rng-octets rng (1+ (rng-below rng 64))))   ; garbage
             (1 (let* ((message (encode-valid-message rng))
                       (contents (wire:buffer-contents message))
                       (cut (rng-below rng (length contents))))
                  (subseq contents 0 cut)))                  ; truncated
             (t (let ((message (encode-valid-message rng)))
                  (wire:buffer-contents message)))))         ; whole messages
         (sent (rng-below rng 3)))
    (ffi:send-with-ancillary writer buffer 0 (length buffer)
                             (if (and (plusp sent) state)
                                 (subseq fds 0 sent)
                                 '()))
    (handler-case
        (io:pump socket input
                 (lambda (object-id opcode reader)
                   (declare (ignore object-id opcode reader))
                   (incf (getf state :messages))))
      (wire:wire-error ()
        ;; Garbage in the stream: the transport has rejected it.  Drop what is
        ;; left so the next iteration starts from a known place -- and close the
        ;; descriptors it had queued, which nobody else will.
        (incf (getf state :rejected))
        (incf (getf state :fds-closed) (close-pending-fds input))))
    (incf (getf state :fds-closed) (close-pending-fds input))
    ;; Invariants: a partial message is bounded by the maximum message size, and
    ;; the buffer only ever doubles from its 64 KiB start.
    (let ((pending (io:input-buffer-pending-octets input))
          (capacity (io:input-buffer-capacity input)))
      (when (> pending (* 2 wire:*max-message-size*))
        (error 'fuzz-failure :case :transport :iteration iteration
                             :detail (format nil "~D octets pending" pending)))
      (when (> capacity (* 4 65536))
        (error 'fuzz-failure :case :transport :iteration iteration
                             :detail (format nil "input buffer grew to ~D octets" capacity))))))

;;; ---------------------------------------------------------------------------
;;; Running it
;;; ---------------------------------------------------------------------------

(defun call-with-deadline (seconds function)
  "Call FUNCTION; return true when it finished within SECONDS.

A decoder that loops forever is a fuzz finding, not a reason to wait.  SBCL is
the only supported implementation, so the watchdog is SB-EXT:WITH-TIMEOUT; a
portable build would only report the hang after the fact."
  #+sbcl
  (handler-case (progn (sb-ext:with-timeout seconds (funcall function)) t)
    (sb-ext:timeout () nil))
  #-sbcl
  (progn (funcall function) t))

(defun open-fd-count ()
  (length (uiop:directory-files #p"/proc/self/fd/")))

(defun run (&key (iterations +default-iterations+) (seed 1)
                 (timeout (max 60 (ceiling iterations 10000)))
                 (stream *standard-output*) (error-stream *error-output*))
  "Run ITERATIONS fuzz cases.  Returns true when every case behaved.

The seed is printed first, always: it is the whole reproduction recipe."
  (let* ((rng (make-seeded-rng seed))
         (messages (all-messages))
         (cases 0)
         (state (list :messages 0 :rejected 0 :fds-closed 0))
         (fds-before (open-fd-count))
         (ok t))
    (when (null messages)
      (format error-stream "~&no protocol schemas registered; load cl-wayland-protocols~%")
      (return-from run nil))
    (format stream "~&fuzz: ~D iterations, seed ~D, ~D messages to decode against~%"
            iterations seed (length messages))
    (multiple-value-bind (socket peer) (ffi:make-socket-pair)
      (let ((input (io:make-input-buffer))
            (pool (loop repeat 4 collect (ffi:memfd-create "cl-wayland-fuzz"))))
        (unwind-protect
             (handler-case
                 (unless (call-with-deadline
                          timeout
                          (lambda ()
                            (dotimes (iteration iterations)
                              (incf cases)
                              (case (rng-below rng 3)
                                (0 (fuzz-header rng iteration))
                                (1 (fuzz-message-decode
                                    rng messages (coerce pool 'vector)))
                                (t (fuzz-transport rng iteration socket peer
                                                   input state pool))))))
                   (setf ok nil)
                   (format error-stream
                           "~&no completion within ~D s (~D of ~D cases); a hang is a finding.~%  seed ~D reproduces it.~%"
                           timeout cases iterations seed))
               (fuzz-failure (condition)
                 (setf ok nil)
                 (format error-stream "~&~A~%  seed ~D reproduces it.~%"
                         condition seed)))
          (dolist (fd pool) (ffi:close-fd fd))
          (ffi:close-fd socket)
          (ffi:close-fd peer)))
      ;; Everything this harness opened is closed by now, so the count is the
      ;; leak check: what the fuzzer provoked must not outlive the case.
      (let ((fds-after (open-fd-count)))
        (unless (= fds-after fds-before)
          (setf ok nil)
          (format error-stream "~&descriptor leak: ~D open before, ~D after~%"
                  fds-before fds-after))))
    (format stream "~&~D case~:P: ~D message~:P dispatched, ~D stream~:P rejected, ~D surplus descriptor~:P closed~%"
            cases
            (getf state :messages)
            (getf state :rejected)
            (getf state :fds-closed))
    (format stream "~&~:[FAILED~;PASSED~]~%" ok)
    ok))

(defun main ()
  "Entry point for scripts/fuzz.sh: run and quit with the verdict.

Arguments are read from the command line: ITERATIONS [SEED]."
  (let* ((arguments (uiop:command-line-arguments))
         (iterations (if arguments
                         (parse-integer (first arguments))
                         +default-iterations+))
         (seed (if (rest arguments)
                   (parse-integer (second arguments))
                   1)))
    (uiop:quit (if (run :iterations iterations :seed seed) 0 1))))

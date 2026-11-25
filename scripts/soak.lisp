;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The soak test: 10k connect/disconnect cycles against the demo server, with
;;;; descriptor count and resident set measured rather than assumed.
;;;;
;;;; Each cycle connects, asks for the registry and a sync (so the server builds
;;;; resources and queues events for it), then closes -- half of them in the
;;;; middle of the exchange, which is the phase-1 gate's "killing clients
;;;; mid-request" clause.  A leak of one descriptor or one client object per
;;;; connection is impossible to miss at 10k.
;;;;
;;;; scripts/soak.sh loads the systems and then this file; SOAK_CYCLES overrides
;;;; the count.

(in-package #:cl-user)

(defun read-file-integer (path)
  "The leading integer of PATH's first line (/proc/self/statm and friends)."
  (with-open-file (stream path)
    (let ((line (read-line stream)))
      (parse-integer line :end (or (position #\Space line) (length line))))))

(defun resident-bytes ()
  "Resident set size of this process, in octets, from /proc/self/statm."
  (* 4096 (read-file-integer "/proc/self/statm")))

(defun open-descriptors ()
  (length (directory (pathname "/proc/self/fd/*"))))

(defun soak-cycle (display cycles)
  "One connection per iteration: ask, sometimes die mid-exchange, move on."
  (dotimes (index cycles)
    (let* ((fd (wayland.ffi:connect-unix-socket
                (wayland.server:display-socket-path display)))
           (buffer (wayland.wire:make-message-buffer)))
      ;; wl_display.get_registry (opcode 1) with new id 2, then wl_display.sync
      ;; (opcode 0) with new id 3.
      (let ((start (wayland.wire:begin-message buffer 1 1)))
        (wayland.wire:put-new-id buffer 2)
        (wayland.wire:end-message buffer start))
      (let ((start (wayland.wire:begin-message buffer 1 0)))
        (wayland.wire:put-new-id buffer 3)
        (wayland.wire:end-message buffer start))
      (handler-case (wayland.io:flush-buffer fd buffer)
        (wayland.ffi:io-error () nil))
      ;; Every other client dies mid-request: the server may have read half of
      ;; what was sent, or none of it.
      (unless (zerop (mod index 2))
        (wayland.server:run-once display :timeout 0))
      (wayland.ffi:close-fd fd)
      (wayland.server:run-once display :timeout 0)
      (wayland.server:run-once display :timeout 0))))

(defun soak (&key (cycles 10000))
  "Run CYCLES connections; return true when nothing leaked.  Prints the numbers."
  ;; 10k connect/disconnect lines are not the evidence; the numbers are.
  (setf wayland.server:*log-level* :warn)
  (let* ((directory (format nil "/tmp/cl-wayland-soak-~D/" (wayland.ffi:process-id)))
         (display nil)
         (ok t))
    (ensure-directories-exist directory)
    (wayland.ffi:chmod-path (string-right-trim "/" directory) #o700)
    (unwind-protect
         (progn
           (setf display (wayland.server:make-demo-display
                          :display-name "soak-0" :runtime-dir directory))
           ;; Warm up: the first connections fault in code and legitimately grow
           ;; the heap, which is not a leak.
           (soak-cycle display 200)
           (let ((fd-before (open-descriptors))
                 (rss-before (resident-bytes))
                 (start (get-internal-real-time)))
             (soak-cycle display cycles)
             ;; Let the last teardowns finish before measuring.
             (loop repeat 4 do (wayland.server:run-once display :timeout 0))
             (let* ((fd-after (open-descriptors))
                    (rss-after (resident-bytes))
                    (elapsed (/ (- (get-internal-real-time) start)
                                internal-time-units-per-second 1.0))
                    (growth (- rss-after rss-before))
                    (leftover (length (wayland.server:display-clients display)))
                    (objects (loop for client in (wayland.server:display-clients display)
                                   sum (wayland.object:object-table-count
                                        (wayland.server:client-objects client)))))
               (format t "soak: ~D cycles in ~,2F s (~,0F/s)~%"
                       cycles elapsed (/ cycles (max elapsed 0.001)))
               (format t "soak: descriptors ~D -> ~D~%" fd-before fd-after)
               (format t "soak: rss ~D -> ~D KiB (growth ~D KiB)~%"
                       (round rss-before 1024) (round rss-after 1024)
                       (round growth 1024))
               (format t "soak: clients left ~D, objects left ~D~%" leftover objects)
               (unless (= fd-before fd-after)
                 (format t "soak: FAILED, the descriptor count changed~%")
                 (setf ok nil))
               ;; A real per-connection leak shows up as megabytes.  Two mebibytes
               ;; of headroom absorbs allocator and page-cache noise without
               ;; hiding anything that grows with the cycle count.
               (when (> growth (* 2 1024 1024))
                 (format t "soak: FAILED, the resident set grew by more than 2 MiB~%")
                 (setf ok nil))
               (unless (zerop leftover)
                 (format t "soak: FAILED, clients survived their connections~%")
                 (setf ok nil)))))
      (when display (wayland.server:close-display display))
      (ignore-errors (uiop:delete-directory-tree (pathname directory) :validate t)))
    ok))

(uiop:quit (if (soak :cycles (parse-integer (or (uiop:getenv "SOAK_CYCLES") "10000")))
               0
               1))

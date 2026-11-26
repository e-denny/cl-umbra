;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; wl_shm, wl_shm_pool and wl_buffer: client pixels in our address space.
;;;;
;;;; This is the boundary where a client can otherwise read our memory or crash
;;;; us, so every number is checked with 64-bit (in Lisp: unbounded) arithmetic
;;;; before a pointer is formed (docs/memory-and-rendering.md §3):
;;;;
;;;;   stride   >= width * 4 and a multiple of 4
;;;;   offset   % 4 == 0
;;;;   offset + stride * (height - 1) + width * 4  <=  pool size
;;;;   width, height > 0 and within a fixed maximum
;;;;   format   one we advertised
;;;;
;;;; A failure is the interface's own error code in wl_display.error -- that is
;;;; how libwayland reports it (wl_resource_post_error carries the interface code)
;;;; -- and the client is disconnected.
;;;;
;;;; Ownership: the fd arrives with the request and is ours from then on.  The
;;;; pool keeps it (a resize needs the file) and closes it when the pool dies;
;;;; the mapping is read-only and shared, because the client keeps writing.
;;;; A buffer is a subrange, never a copy: the renderer reads the client's pixels
;;;; in place.

(in-package #:wayland.server)

;;; ---------------------------------------------------------------------------
;;; Formats
;;; ---------------------------------------------------------------------------

(defconstant +wl-shm-format-argb8888+ 0
  "Premultiplied A:R:G:B, the default for toolkits.")

(defconstant +wl-shm-format-xrgb8888+ 1
  "Opaque x:R:G:B, what terminals and video players usually send.")

(defparameter *shm-formats*
  (list +wl-shm-format-argb8888+ +wl-shm-format-xrgb8888+)
  "Advertised in this order on bind, mimicking libwayland (docs/memory-and-rendering.md §5).

Phase 5 adds the bgr/rgb/565 family behind the renderer's capability list; until
there is a renderer that wants them, advertising them would be a lie.")

(defparameter *shm-max-pool-size* (* 512 1024 1024)
  "Largest pool we will map.  A client asking for more is not rendering a screen.")

(defparameter *shm-max-dimension* 16384
  "Largest buffer side, in pixels.  Four of these already exceed 4K.")

(defun shm-format-supported-p (format)
  (and (integerp format) (member format *shm-formats*) t))

(defun shm-format-bytes-per-pixel (format)
  (ecase format
    ((0 1) 4)))

(defun send-shm-formats (shm)
  "The wl_shm.format events a client gets the moment it binds wl_shm."
  (dolist (format *shm-formats*)
    (wl-shm.format shm format))
  shm)

;;; ---------------------------------------------------------------------------
;;; Buffers as pixel memory
;;; ---------------------------------------------------------------------------

(defun shm-buffer-pointer (buffer)
  "The first pixel of BUFFER, inside its pool's mapping.

Only valid while the pool is alive; the pool destroys its buffers before it
unmaps, so a buffer that exists has a mapping."
  (let* ((pool (shm-buffer-pool buffer))
         (mapping (shm-pool-mapping pool)))
    (unless mapping
      (error 'internal-error
             :client (resource-client buffer)
             :detail "buffer points into a pool that is not mapped"))
    (wayland.ffi:pointer+ mapping (shm-buffer-offset buffer))))

(defun shm-buffer-byte-length (buffer)
  "Octets BUFFER's pixels span, from its offset to its last row."
  (let ((stride (shm-buffer-stride buffer))
        (width (shm-buffer-width buffer))
        (height (shm-buffer-height buffer)))
    (+ (* stride (1- height)) (* width 4))))

(defun release-shm-buffer (buffer)
  "Tell the client it may reuse BUFFER's pixels.  Never twice."
  (unless (resource-destroyed-p buffer)
    (unless (shm-buffer-released-p buffer)
      (setf (shm-buffer-released-p buffer) t)
      (setf (shm-buffer-in-use-p buffer) nil)
      (wl-buffer.release buffer)))
  buffer)

;;; ---------------------------------------------------------------------------
;;; Destruction
;;; ---------------------------------------------------------------------------

(defun release-shm-pool-mapping (pool)
  "Unmap the pixels and close the file descriptor, once nothing needs them."
  (when (shm-pool-mapping pool)
    (wayland.ffi:unmap-file (shm-pool-mapping pool)
                            (shm-pool-mapping-length pool))
    (setf (shm-pool-mapping pool) nil
          (shm-pool-mapping-length pool) 0))
  (when (>= (shm-pool-fd pool) 0)
    (close-fd (shm-pool-fd pool))
    (setf (shm-pool-fd pool) -1))
  pool)

(defun destroy-shm-buffer (buffer)
  "Drop BUFFER's reference to the pool; unmap if it was the last one.

wl_shm_pool.destroy may happen immediately after create_buffer -- the protocol
says a buffer keeps the pool alive -- so the mapping belongs to the *buffers* in
practice, and the last one out turns off the lights."
  (let ((pool (shm-buffer-pool buffer)))
    (setf (shm-pool-buffers pool)
          (remove buffer (shm-pool-buffers pool)))
    ;; The pool object is gone and this was its last buffer: nobody can see those
    ;; pixels again.
    (when (and (resource-destroyed-p pool)
               (null (shm-pool-buffers pool)))
      (release-shm-pool-mapping pool))))

(defun destroy-shm-pool (pool)
  "The pool object dies; its pixels live until its last buffer does.

The descriptor is closed here (the mapping does not need it), and the mapping
stays while buffers reference it.  Closing the fd early is not just tidiness: a
client that destroys its pool and keeps drawing has no business keeping a
descriptor alive in our process."
  (when (>= (shm-pool-fd pool) 0)
    (close-fd (shm-pool-fd pool))
    (setf (shm-pool-fd pool) -1))
  (when (null (shm-pool-buffers pool))
    (release-shm-pool-mapping pool)))

;;; ---------------------------------------------------------------------------
;;; Requests
;;; ---------------------------------------------------------------------------

(defmethod wl-shm.create-pool ((shm shm) fd size)
  "Map the client's file read-only and hold it for the pool's life.

The descriptor arrives with the message and is ours from here: every failure
path closes it, because the kernel's duplicate is nobody else's to close."
  (let* ((client (resource-client shm))
         (object-id (resource-id shm))
         (size-ok (and (integerp size) (<= 1 size *shm-max-pool-size*))))
    (unless size-ok
      (close-fd fd)
      (protocol-error client object-id +wl-shm-error-invalid-fd+
                      "pool size ~S is not between 1 and ~D octets"
                      size *shm-max-pool-size*))
    (let ((mapping (handler-case (wayland.ffi:map-file fd size)
                     (wayland.ffi:io-error (condition)
                       (declare (ignore condition))
                       (close-fd fd)
                       (protocol-error client object-id +wl-shm-error-invalid-fd+
                                       "cannot map ~D octets for the pool" size)))))
      (let ((pool (allocate-resource client
                                     (resolve-interface "wl_shm_pool")
                                     :version (resource-version shm)
                                     :class 'shm-pool
                                     :destroy-function #'destroy-shm-pool)))
        (setf (shm-pool-fd pool) fd
              (shm-pool-size pool) size
              (shm-pool-mapping pool) mapping
              (shm-pool-mapping-length pool) size)
        pool))))

(defmethod wl-shm-pool.create-buffer ((pool shm-pool) offset width height stride format)
  "Validate the subrange, then create a wl_buffer that points into the pool.

Every check here is a check a malicious client would otherwise turn into a read
of our address space or a crash: they are all done before a pointer exists."
  (let ((client (resource-client pool))
        (object-id (resource-id pool)))
    (flet ((reject (code control &rest arguments)
             (apply #'protocol-error client object-id code control arguments)))
      (unless (shm-format-supported-p format)
        (reject +wl-shm-pool-error-invalid-format+
                "buffer format ~S is not one we advertised (~{~D~^, ~})"
                format *shm-formats*))
      (unless (and (integerp width) (integerp height)
                   (plusp width) (plusp height)
                   (<= width *shm-max-dimension*)
                   (<= height *shm-max-dimension*))
        (reject +wl-shm-pool-error-invalid-stride+
                "buffer dimensions ~Sx~S are not in 1..~D"
                width height *shm-max-dimension*))
      (unless (and (integerp stride)
                   (>= stride (* width (shm-format-bytes-per-pixel format)))
                   (zerop (mod stride 4)))
        (reject +wl-shm-pool-error-invalid-stride+
                "stride ~S is too small for width ~D or not a multiple of 4"
                stride width))
      (unless (and (integerp offset) (not (minusp offset)) (zerop (mod offset 4)))
        (reject +wl-shm-pool-error-invalid-stride+
                "offset ~S is negative or not a multiple of 4" offset))
      (let ((needed (+ offset (* stride (1- height)) (* width 4))))
        (unless (<= needed (shm-pool-size pool))
          (reject +wl-shm-pool-error-invalid-stride+
                  "buffer needs ~D octets from offset ~D, but the pool is ~D"
                  needed offset (shm-pool-size pool)))))
    (let ((buffer (allocate-resource client
                                     (resolve-interface "wl_buffer")
                                     :version 1
                                     :class 'shm-buffer
                                     :destroy-function #'destroy-shm-buffer)))
      (setf (shm-buffer-pool buffer) pool
            (shm-buffer-offset buffer) offset
            (shm-buffer-width buffer) width
            (shm-buffer-height buffer) height
            (shm-buffer-stride buffer) stride
            (shm-buffer-format buffer) format)
      (push buffer (shm-pool-buffers pool))
      buffer)))

(defmethod wl-shm-pool.destroy ((pool shm-pool))
  (destroy-resource pool))

(defmethod wl-buffer.destroy ((buffer shm-buffer))
  (destroy-resource buffer))

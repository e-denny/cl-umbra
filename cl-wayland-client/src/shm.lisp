;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; wl_shm on the client side: a memfd, a mapping, and the buffers cut out of it.
;;;;
;;;; The client side of shm is the mirror of the compositor's (docs/protocol-layer.md
;;;; §2): it names a size, writes the pixels itself, and sends the descriptor once.
;;;; After wl_shm.create_pool the descriptor belongs to the compositor too, so the
;;;; client keeps its own copy only because its mapping was made from it.
;;;;
;;;; A pool here is a CLIENT-POOL (fd, mapping, size) plus the wl_shm_pool proxy; a
;;;; buffer is a CLIENT-BUFFER (a rectangle of that mapping) plus the wl_buffer
;;;; proxy.  The structs are what code touches; the proxies are what the wire
;;;; touches, and DESTROY-CLIENT-BUFFER / DESTROY-CLIENT-POOL release each half
;;;; separately because their lifetimes are different (D25: a buffer outlives the
;;;; pool that made it, on the compositor's side).
;;;;
;;;; Pixel access is provided for tests and for tiny clients, not as an API to
;;;; build a toolkit on: the nested backend renders into the mapping through
;;;; pixman, and never calls CLIENT-BUFFER-PIXEL once per frame.

(in-package #:wayland.client)

;;; ---------------------------------------------------------------------------
;;; The objects
;;; ---------------------------------------------------------------------------

(defclass shm (proxy) ()
  (:documentation "wl_shm: the shared-memory factory, and the format list."))

(defclass shm-pool (proxy) ()
  (:documentation "wl_shm_pool: one descriptor, mapped once, cut into buffers."))

(register-proxy-class "wl_shm" 'shm)
(register-proxy-class "wl_shm_pool" 'shm-pool)

;;; ---------------------------------------------------------------------------
;;; A pool: descriptor, mapping, size
;;; ---------------------------------------------------------------------------

(defstruct (client-pool (:constructor %make-client-pool))
  (proxy nil)
  (fd -1 :type fixnum)
  (pointer (cffi:null-pointer) :type cffi:foreign-pointer)
  (size 0 :type fixnum))

(defmethod wl-shm.create-pool ((shm shm) fd size)
  "Announce a descriptor and its size as a pool.  The descriptor itself travels as
ancillary data and occupies no octets (D23)."
  (check-live shm)
  (let ((pool (allocate-child shm "wl_shm_pool" :class 'shm-pool)))
    (send-request shm (interface-request (proxy-interface shm) 0)
                  (proxy-id pool) fd size)
    pool))

(defmethod wl-shm-pool.create-buffer ((pool shm-pool) offset width height stride format)
  "Cut a buffer out of POOL; the pixels are already there, so nothing is sent but
the geometry and the format code."
  (check-live pool)
  (let ((buffer (allocate-child pool "wl_buffer" :class 'buffer)))
    (send-request pool (interface-request (proxy-interface pool) 0)
                  (proxy-id buffer) offset width height stride format)
    buffer))

(defmethod wl-shm-pool.resize ((pool shm-pool) size)
  "Ask the compositor to take note of a larger pool file."
  (check-live pool)
  (send-request pool (interface-request (proxy-interface pool) 2) size))

(defmethod print-object ((pool client-pool) stream)
  (print-unreadable-object (pool stream :type t)
    (format stream "~D octets, fd ~D" (client-pool-size pool) (client-pool-fd pool))))

(defun make-client-pool (shm size)
  "A memfd of SIZE octets, mapped read-write, announced as a wl_shm_pool.

The descriptor stays open: the mapping is what the client reads, but a later
resize would need the descriptor again, and one fd per pool is nothing."
  (unless (and (integerp size) (plusp size))
    (error 'client-error
           :detail (format nil "a pool needs a positive size, got ~S" size)))
  (let ((fd (memfd-create "cl-wayland-pool"))
        (pointer (cffi:null-pointer)))
    (handler-case
        (progn
          (set-file-size fd size)
          (setf pointer (map-file fd size
                                  :protection (logior +prot-read+ +prot-write+)))
          (let ((proxy (wl-shm.create-pool shm fd size)))
            (%make-client-pool :proxy proxy :fd fd :pointer pointer :size size)))
      (error (condition)
        (when (and pointer (not (cffi:null-pointer-p pointer)))
          (ignore-errors (unmap-file pointer size)))
        (when (fd-open-p fd)
          (ignore-errors (close-fd fd)))
        (error condition)))))

(defun destroy-client-pool (pool)
  "Unmap the pool and destroy the proxy; buffers cut from it are not touched."
  (let ((proxy (client-pool-proxy pool)))
    (when (and proxy (not (proxy-destroyed-p proxy)))
      (ignore-errors (wl-shm-pool.destroy proxy)))
    (when (plusp (client-pool-size pool))
      (unmap-file (client-pool-pointer pool) (client-pool-size pool))
      (setf (client-pool-pointer pool) (cffi:null-pointer)
            (client-pool-size pool) 0))
    (when (fd-open-p (client-pool-fd pool))
      (close-fd (client-pool-fd pool))
      (setf (client-pool-fd pool) -1)))
  nil)

;;; ---------------------------------------------------------------------------
;;; A buffer: a rectangle of a pool
;;; ---------------------------------------------------------------------------

(defstruct (client-buffer (:constructor %make-client-buffer))
  (proxy nil)
  (pool nil)
  (offset 0 :type fixnum)
  (width 0 :type fixnum)
  (height 0 :type fixnum)
  (stride 0 :type fixnum)
  (format 0 :type integer))

(defmethod print-object ((buffer client-buffer) stream)
  (print-unreadable-object (buffer stream :type t)
    (format stream "~Dx~D stride ~D format ~D"
            (client-buffer-width buffer) (client-buffer-height buffer)
            (client-buffer-stride buffer) (client-buffer-format buffer))))

(defun allocate-client-buffer (pool &key (offset 0)
                                         width height
                                         (stride (and width (* width 4)))
                                         (format 0))
  "Cut a buffer of WIDTH x HEIGHT at OFFSET out of POOL and announce it.

FORMAT is the wl_shm format code: 0 = ARGB8888 (premultiplied), 1 = XRGB8888.
The bounds check is the client's own: a buffer is a promise about the file's size,
and the compositor's refusal would arrive as a protocol error after the pixels
were already written."
  (unless (and (integerp width) (plusp width)
               (integerp height) (plusp height)
               (integerp stride) (plusp stride)
               (>= stride (* width 4))
               (zerop (mod stride 4)))
    (error 'client-error
           :detail (format nil "bad buffer geometry ~Sx~S stride ~S"
                           width height stride)))
  (let ((required (+ offset (* stride height))))
    (unless (and (>= offset 0) (<= required (client-pool-size pool)))
      (error 'client-error
             :detail (format nil "a ~Dx~D buffer at ~D needs ~D octets; the pool has ~D"
                             width height offset required (client-pool-size pool))))
    (let ((proxy (wl-shm-pool.create-buffer (client-pool-proxy pool)
                                            offset width height stride format)))
      (%make-client-buffer :proxy proxy :pool pool
                           :offset offset :width width :height height
                           :stride stride :format format))))

(defmethod object-id-of ((buffer client-buffer))
  "A client buffer goes on the wire as its wl_buffer id, so ATTACH takes the struct."
  (proxy-id (client-buffer-proxy buffer)))

(defun destroy-client-buffer (buffer)
  "Destroy the wl_buffer proxy.  The pixels belong to the pool, not the buffer."
  (let ((proxy (client-buffer-proxy buffer)))
    (when (and proxy (not (proxy-destroyed-p proxy)))
      (ignore-errors (wl-buffer.destroy proxy)))
    nil))

;;; ---------------------------------------------------------------------------
;;; Pixels, for tests and small clients
;;; ---------------------------------------------------------------------------

(defun client-buffer-pointer (buffer)
  "A pointer to the buffer's first pixel."
  (pointer+ (client-pool-pointer (client-buffer-pool buffer))
            (client-buffer-offset buffer)))

(defun buffer-offset-for (buffer x y)
  (unless (and (<= 0 x) (< x (client-buffer-width buffer))
               (<= 0 y) (< y (client-buffer-height buffer)))
    (error 'client-error
           :detail (format nil "(~D, ~D) is outside a ~Dx~D buffer"
                           x y (client-buffer-width buffer) (client-buffer-height buffer))))
  (+ (* y (client-buffer-stride buffer)) (* x 4)))

(defun client-buffer-pixel (buffer x y)
  "The 0xAARRGGBB pixel at X, Y, read straight from the mapping."
  ;; MEM-AREF indexes in *elements*, not octets: a :UINT32 at octet offset OFF is
  ;; element (OFF / 4), and getting that wrong writes 4x past the pool.
  (cffi:mem-aref (client-buffer-pointer buffer) :uint32
                 (ash (buffer-offset-for buffer x y) -2)))

(defun (setf client-buffer-pixel) (argb buffer x y)
  (setf (cffi:mem-aref (client-buffer-pointer buffer) :uint32
                       (ash (buffer-offset-for buffer x y) -2))
        argb)
  argb)

(defun client-buffer-fill (buffer argb)
  "Fill the whole buffer with a 0xAARRGGBB colour."
  (client-buffer-fill-rect buffer 0 0 (client-buffer-width buffer)
                           (client-buffer-height buffer) argb))

(defun client-buffer-fill-rect (buffer x y width height argb)
  "Fill a buffer-local rectangle; clipped to the buffer, not an error outside it."
  (let ((x1 (max 0 x))
        (y1 (max 0 y))
        (x2 (min (client-buffer-width buffer) (+ x width)))
        (y2 (min (client-buffer-height buffer) (+ y height))))
    (loop for row from y1 below y2
          do (loop for column from x1 below x2
                   do (setf (client-buffer-pixel buffer column row) argb))))
  buffer)

;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later

(in-package #:cl-user)

;;; The modules come first, and CF re-exports their public names: one package per
;;; module is how docs/framework.md §1 lays the framework out, and CF is the face
;;; a compositor author writes against.

(defpackage #:cf.render.pixman
  (:use #:cl)
  (:documentation
   "The pixman renderer: the reference implementation, and by definition the
output golden tests compare against (docs/memory-and-rendering.md §6-§7).

It draws into a `target' -- a pixman image over an octet vector -- from wl_shm
buffers, which are read in place: no copy, no texture, no upload.")
  (:export
   #:make-target
   #:fill-target
   #:composite-buffer
   #:render-surface
   #:pixman-format-for-shm
   #:+pixman-op-src+
   #:+pixman-op-over+))

(defpackage #:cf.backend.headless.png
  (:use #:cl)
  (:documentation
   "PNG writing for readback: the smallest correct encoder (stored deflate blocks,
one filter byte per scanline, real CRC-32 and Adler-32), because a screenshot is
a debugging artefact and a test fixture, not a compression benchmark.")
  (:export #:write-png))

(defpackage #:cf.backend.headless
  (:use #:cl)
  (:local-nicknames (#:render #:cf.render.pixman)
                    (#:png #:cf.backend.headless.png)
                    (#:srv #:wayland.server)
                    (#:reactor #:wayland.reactor))
  (:import-from #:wayland
                #:wl-surface.enter
                #:wl-output.geometry
                #:wl-output.mode
                #:wl-output.scale
                #:wl-output.name
                #:wl-output.description
                #:wl-output.done)
  (:documentation
   "The headless backend: an in-memory target of a configured size, an idle-driven
frame clock, and `read-pixels' for golden tests (docs/memory-and-rendering.md §8.1).")
  (:export
   #:make-headless-compositor
   #:render-frame
   #:frame-pixel
   #:target-octets
   #:compositor-display
   #:compositor-width
   #:compositor-height
   #:compositor-surfaces
   #:compositor-target
   #:compositor-frame-count
   #:compositor-target
   #:write-frame-png
   #:cf-surface
   #:cf-compositor))

(defpackage #:cf
  (:use #:cl)
  (:nicknames #:cl-compositor-framework)
  (:import-from #:cf.backend.headless
                #:make-headless-compositor
                #:write-frame-png
                #:render-frame
                #:frame-pixel
                #:compositor-display
                #:compositor-width
                #:compositor-height
                #:compositor-surfaces
                #:compositor-frame-count
                #:cf-surface
                #:cf-compositor)
  (:import-from #:cf.render.pixman
                #:make-target
                #:fill-target
                #:composite-buffer
                #:render-surface
                #:pixman-format-for-shm)
  (:import-from #:cf.backend.headless.png
                #:write-png)
  (:documentation
   "The compositor framework: everything wlroots provides, in Lisp.

Phase 2a is the first slice with code in it: `CF.RENDER.PIXMAN` is the reference
renderer (docs/memory-and-rendering.md §7) and `CF.BACKEND.HEADLESS` is the
output path that needs no privileges, no display and no hardware
(docs/memory-and-rendering.md §8.1).  The other modules named in
docs/framework.md §1 follow.")
  (:export
   ;; the headless compositor
   #:make-headless-compositor
   #:render-frame
   #:frame-pixel
   #:compositor-display
   #:compositor-width
   #:compositor-height
   #:compositor-surfaces
   #:compositor-frame-count
   #:write-png
   #:write-frame-png
   ;; the renderer
   #:make-target
   #:fill-target
   #:composite-buffer
   #:render-surface
   #:pixman-format-for-shm
   ;; protocol subclasses
   #:cf-surface
   #:cf-compositor))

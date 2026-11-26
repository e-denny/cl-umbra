# Memory and rendering — the shm-first design

The compositor's job is: get pixels from clients, put them on a screen, tell clients when to
draw again. Almost every architectural mistake in a compositor comes from deciding *where
those pixels live* too late. This document fixes that: **shared memory first, CPU
compositing as the reference, GPU as an optimization.**

---

## 1. Why shm first

1. `wl_shm` is the one buffer path every client must support. If it works, every client can
   draw, in every environment, on every driver.
2. It needs no EGL, no GBM, no dmabuf, no modifiers, no fences, no format negotiation
   beyond four formats. That removes ~80 % of the graphics-stack risk from the critical
   path.
3. The compositor gets a plain mmap'd window of pixels it can read, composite, diff and hash.
   Golden-image tests become trivial and run on machines without a GPU.
4. Real hardware is reachable with **dumb buffers** (`DRM_IOCTL_MODE_CREATE_DUMB`), which are
   also just mmap'd linear memory. A complete TTY compositor with zero GL is possible.
5. It is the fallback that makes every later GPU path safe: when dmabuf import fails, when a
   modifier is unsupported, when the GPU is busy or gone, the shm path still renders.

The trade is bandwidth (see §10), and it is a trade that can be reversed per-surface later
without changing the scene graph or the protocol layer.

## 2. Who owns what

| Memory | Created by | Mapped by | Freed by | Lifetime |
|---|---|---|---|---|
| `wl_shm_pool` | client (`memfd`/shm fd, passed via `SCM_RIGHTS`) | compositor (`mmap`, read-only) | `wl_shm_pool.destroy` / client disconnect | per client |
| `wl_buffer` (shm) | client (`create_buffer`, offset into pool) | inherits the pool mapping | `wl_buffer.destroy` / pool destroy | until released |
| Framework buffers (cursor images, wallpaper, decorations) | compositor (`memfd_create`) | compositor | owner object's `release` | per owner |
| Render target (headless/nested) | compositor (`memfd_create`) | compositor | output destroy | per output |
| DRM dumb buffer | compositor (ioctl → handle → mmap) | compositor | output destroy (`RMFB`, `DESTROY_DUMB`) | per output |
| Keymap | compositor (`memfd_create` from libxkbcommon string) | client (read-only) | after `wl_keyboard.keymap` is sent and the client has read it | one-shot |
| Swapchain / dmabuf (phase 5) | compositor (GBM) | GPU | output destroy | per output |

Rules:

- **No foreign memory is GC-managed.** Every mapping has an owner object with an explicit
  `release`. Finalizers exist only as leak detectors that log (see `architecture.md` §7).
- Every mmap is paired with exactly one munmap on one idempotent path.
- fds are always `CLOEXEC`; we never assume a client's fd was.

## 3. Pools and buffers

```lisp
;; on wl_shm.create_pool(fd, size) and wl_shm_pool.create_buffer(...)
(defstruct shm-pool
  (fd -1)            ; our dup of the client's fd, CLOEXEC
  (size 0 :type (unsigned-byte 64))
  (mapping nil)      ; sap or nil
  (refcount 0))
```

Mechanics:

- The pool's fd is received via `SCM_RIGHTS`, immediately `dup`'d if it must survive the
  message, and `mmap`'d `PROT_READ` `MAP_SHARED`. The client keeps writing; we read.
- `wl_shm_pool.resize` grows the mapping (`mremap` or unmap+mmap); shrinking is not allowed
  by the protocol. The mapping is only ever remapped when no buffer subrange is in flight,
  or buffers are re-validated afterwards.
- Buffers are `(offset, width, height, stride, format)` subranges. Validation is 64-bit
  arithmetic and is not negotiable:

```
stride >= width * bytes-per-pixel(format)      ; and stride % 4 == 0 in practice
offset + stride * (height - 1) + width * bpp <= pool.size
width, height > 0 and <= 16384 (configurable)
format in our advertised wl_shm.format list
offset % 4 == 0
```

  Anything else is `wl_shm.error(invalid-stride | invalid-fd | invalid-format)`, and the
  client is disconnected. This is the boundary where a malicious client would otherwise
  read our memory or crash us.
- **Pool and buffer lifetime** (phase 2a, implemented): `wl_shm_pool.destroy` may happen
  immediately after `create_buffer` — the protocol says a buffer keeps its pool alive — so the
  *buffers* own the mapping in practice. Destroying the pool closes its descriptor at once and
  leaves the mapping to the last buffer; destroying the last buffer unmaps it. Destroying a
  surface releases its buffer, so a client that never destroys a buffer explicitly still gets
  its release when the surface goes. The earlier idea of destroying a pool's buffers with the
  pool was wrong and was caught by the first real client: it destroyed the pool after creating
  its buffer and then attached a buffer we had already destroyed.
- `wl_buffer.release` is sent when the compositor is finished with the buffer for a frame.
  Release must never happen for a buffer that is still referenced by a queued frame, and must
  happen promptly or clients stall. Since phase 3 the release happens at **presentation**: the
  renderer copies the buffer into the target, then releases it, then fires the frame callbacks
  (D25). A buffer replaced by a later commit before it was presented is released at that
  commit, so a burst of commits in one batch cannot strand one. Phase 2a released only at the
  next commit, which is a claim about our scheduling rather than the protocol's, and
  `weston-simple-shm` deadlocked on it after two frames.
- Claiming matters as much as releasing: `wl_surface.attach` with a non-nil buffer sets
  `released-p` to NIL (`claim-shm-buffer`), which is what makes the release a real event rather
  than a no-op. Before that fix every release was silently skipped, including the phase-2a
  one.
- Buffer reuse without release is the single most common client-vs-compositor bug; the test
  suite has explicit cases (`attach` while still in use, `attach` then immediate `destroy`,
  commit with no buffer, damage-only commit).

## 4. The SIGBUS problem (honest version)

`wl_shm` gives the client an fd it can `ftruncate` at any time. If the client shrinks its
file after we mapped it, touching the truncated pages raises `SIGBUS`, and a compositor that
dies on `SIGBUS` has a trivially exploitable crash.

What we do:

1. Validate at pool creation and at every buffer creation/commit (§3).
2. Keep the pool size we were told and re-check on commit; a `resize` updates it.
3. When the pool fd is a `memfd` created with `MFD_ALLOW_SEALING`, opportunistically add
   `F_SEAL_SHRINK` — but only if the client has not used `wl_shm_pool.resize`, because
   sealing shrink would break legitimate growth.
4. Residual risk is accepted and documented, as it is in wlroots/sway. Full mitigation is a
   candidate for the Rust shim: a small `memcpy`-under-`sigsetjmp` helper that turns a fault
   during a copy into an error return. Not worth doing until phase 6.

## 5. Formats

Advertised (`wl_shm.format`), in this order (mimicking libwayland's ordering):

| Wayland format | pixman format | Notes |
|---|---|---|
| `argb8888` | `PIXMAN_a8r8g8b8` | premultiplied; the default for toolkits |
| `xrgb8888` | `PIXMAN_x8r8g8b8` | opaque; most video players, terminals |
| `abgr8888` | `PIXMAN_a8b8g8r8` | phase 5 |
| `xbgr8888` | `PIXMAN_x8b8g8r8` | phase 5 |
| `rgb565` | `PIXMAN_r5g6b5` | phase 5, low-bandwidth clients |
| `bgr888`, `rgb888` | `PIXMAN_b8g8r8`, `PIXMAN_r8g8b8` | phase 5 |

Phase 2a advertises exactly the first two, in this order: the renderer implements those two,
and advertising formats a compositor cannot draw would be a lie a client cannot see. The
pixman codes are pixman's `PIXMAN_FORMAT(bpp, type, a, r, g, b)` macro spelled out
(`0x20028888` for a8r8g8b8), with the arithmetic in the source so it can be checked against
the header.

Wayland buffer alpha is **premultiplied**; do not un-premultiply anywhere on the hot path.
Colour space is sRGB assumed by default, with `wp-color-management` (phase 7) able to say
otherwise; until then, no implicit conversions.

## 6. The renderer interface

Everything draws through one protocol, so the pixman and GLES2 implementations are
interchangeable and separately testable:

```lisp
(defgeneric begin (renderer output width height))
(defgeneric end (renderer))

(defgeneric render-buffer (renderer buffer
                           &key x y width height
                                transform scale filter
                                alpha clip))

(defgeneric clear (renderer colour &key damage))
(defgeneric read-pixels (renderer &key x y width height))  ; → (values octets format w h)
(defgeneric supported-shm-formats (renderer))
(defgeneric buffer-usable-p (renderer buffer))             ; dmabuf fallback decisions
```

Semantics:

- `begin` acquires a target for an output: an shm mapping (headless/nested) or a dumb buffer
  mapping (DRM). `end` publishes it (PNG write, `wl_surface.attach`+`commit` to the parent,
  or page flip).
- Coordinates are output-local, in device pixels after `scale` and `transform` are applied
  by the caller (`cf.output`). The renderer never knows about layout coordinates.
- `clip` is a region (pixman region or an array of rects for GL scissor).
- `read-pixels` exists for screenshots, screencopy and golden tests; it must work with every
  renderer, which is why the pixman renderer is the reference: its output is the definition
  of correct.

## 7. The pixman renderer

```lisp
(defun %image (buffer)
  (pixman_image_create_bits (pixman-format (buffer-format buffer))
                            (buffer-width buffer) (buffer-height buffer)
                            (sap+ (pool-mapping (buffer-pool buffer)) (buffer-offset buffer))
                            (buffer-stride buffer)))

(defun render-buffer (renderer buffer &key x y clip alpha …)
  (let ((src (%image buffer)))
    (pixman_image_set_clip_region32 (target-image renderer) clip)
    (pixman_image_composite32 +pixman-op-over+ src nil (target-image renderer)
                               0 0  0 0  x y  width height)))
```

Phase 2a implements the target, `composite-buffer` and `render-surface` from that sketch:
`PIXMAN_OP_SRC` for `xrgb8888` into a cleared target and `PIXMAN_OP_OVER` for `argb8888`, the
conversion `0xAARRGGBB` ↔ `PIXMAN_a8r8g8b8`, and readback through the target's octet vector.
Not yet: clip regions, scaling, transforms, buffer age and damage scissoring — the notes below
are the plan for them, and the full-target repaint is honest until they exist.

Notes that matter for correctness and speed:

- `PIXMAN_OP_SRC` for the first opaque surface into a cleared target, `PIXMAN_OP_OVER`
  otherwise. Choosing `OVER` everywhere is measurably slower and occasionally wrong with
  opaque formats.
- Scaling: `pixman_image_set_transform` + `pixman_image_set_filter` (bilinear) for
  fractional scale and for clients that drew at a different buffer scale. Nearest for
  integer scales — it is both faster and sharper.
- Rotated outputs: composite into an intermediate target in output-local space, then
  transform once into the scanout buffer. Per-surface rotation is a slow path and is not
  implemented.
- Buffer age: track which target slot each buffer's contents came from; if
  `buffer-age <= slots`, only repaint the damage accumulated since that frame. With two
  slots, oldest-useful age is 2.
- Damage: a pixman region per frame, unioned from surface damage, moved/reshaped surfaces,
  and output-level invalidation. Full repaint on mode change, scale change, or age
  invalidation.
- Draw order: background → bottom layer → toplevels (back to front) → top layer → overlay
  layer → cursor → (later) effects passes.

Measured expectations on the development machine (Renoir, DDR4-3200):

| Workload | Est. CPU/frame |
|---|---|
| 1080p, one fullscreen opaque client, damage-scissored | 0.5-1.5 ms |
| 1080p, five overlapping ARGB windows | 2-4 ms |
| 4K, one fullscreen opaque client | 2-4 ms |
| 4K, five overlapping ARGB windows | 8-14 ms |

So: 1080p is comfortable; 4K is usable but leaves little headroom; blur at 4K on CPU is not
viable. That is exactly why the next section is ordered DRM-dumb-first and GL-second.

## 8. Output paths

### 8.1 Headless

Render into a memfd-backed shm target, then either measure time and drop it, or write a PNG
on demand. This is the CI workhorse: no display, no privileges, deterministic pixels.

Phase 2a implements it, with one simplification: the target is a Lisp octet vector rather
than a memfd (pixman draws into it in place either way, and a vector is easier to read back
and to pin), and the frame clock is a reactor *idle* — a commit marks the compositor dirty
and one render happens at the end of that cycle. A commit-driven idle is the right shape for a
headless output with no vblank; the timer/vblank clock replaces it without touching the
renderer or the surface objects. Rendering flushes the connections it produced events for:
frame callbacks are queued by the render, after the read loop already flushed, and an event
nobody writes is an event the client waits for forever.

### 8.2 Nested (compositor inside a compositor)

Our compositor is a Wayland *client* of the parent (using `cl-wayland-client`): it creates
`wl_shm` pools for its outputs, renders into them, then `wl_surface.attach`/`commit`. Input
arrives as `wl_pointer`/`wl_keyboard` events from the parent's seat. This is how `cl-tinywl`
is developed before touching DRM, and it exercises both protocol directions at once.

### 8.3 DRM/KMS with dumb buffers (phases 4-6)

No EGL. libdrm's helpers keep this small — the whole path is roughly these calls:

| Step | libdrm call | Notes |
|---|---|---|
| open device | `open("/dev/dri/cardN", O_RDWR\|O_NONBLOCK)` | via libseat's `open_device` for session handling |
| enumerate | `drmModeGetResources`, `drmModeGetConnector`, `drmModeGetEncoder`, `drmModeGetCrtc` | pick connected connector + its current/new CRTC, preferred mode |
| allocate | `drmModeCreateDumbBuffer(fd, w, h, 32, 0, &handle, &pitch, &size)` | pitch is driver-chosen; do not assume width×4 |
| map | `drmModeMapDumbBuffer(fd, handle, &offset)` then `mmap(size)` | our scanout memory |
| register | `drmModeAddFB(fd, w, h, depth=24, bpp=32, pitch, handle, &fb_id)` | |
| set mode | `drmModeSetCrtc(fd, crtc, fb_id, 0, 0, &connector, 1, &mode)` | once per output |
| present | `drmModePageFlip(fd, crtc, fb_id, DRM_MODE_PAGE_FLIP_EVENT, user_data)` | non-blocking |
| wait | `read(drm_fd)` → `drm_event_vblank` | gives vblank timestamp for frame callbacks |
| teardown | `drmModeRmFB`, `DESTROY_DUMB`, `munmap` | idempotent |

Frame pacing: double or triple buffer, flip on the previous flip's completion, and send
`wl_surface.frame` callbacks from the vblank timestamp — not when rendering finishes. This
single detail is the difference between smooth and stuttery output, and it is why page-flip
completion is the output's clock rather than a timer.

Known limitations that phase 5 removes: no hardware cursor plane, no overlay planes, no
dmabuf, no VRR/HDR, no direct scanout. Software cursor is composited into the scanout buffer.

### 8.4 GBM/EGL and atomic KMS (phase 5)

Swapchain of GBM buffers with modifiers, EGL render target, `eglSwapBuffersWithDamageKHR`,
`drmModeAtomicCommit` with plane properties, hardware cursor plane, `IN_FENCE_FD`/
`OUT_FENCE_PTR` for explicit sync, plane offloading for direct scanout. Everything behind
the same renderer interface, with an automatic fallback to the dumb-buffer path if context
creation or import fails.

## 9. Readback

Screenshots, `wlr-screencopy`, and the test harness all use `read-pixels`:

- Pixman renderer: composite the requested region into a staging shm buffer and copy out.
  Phase 2a's smaller version: the target *is* the buffer, `frame-pixel` reads one pixel for
  assertions, and `write-png` writes the whole thing (stored deflate blocks, RGBA8, real
  CRC-32 and Adler-32 — no compression library, because a screenshot is evidence).
- GL renderer: `glReadPixels` (slow, acceptable for a screenshot) or a blit + shm download.
- DRM: read from the scanout buffer mapping directly if it is still the displayed one;
  otherwise render a fresh frame into a staging buffer.

Screenshots must never require a roundtrip through the compositor's own Wayland connection.

## 10. Bandwidth, and when CPU compositing stops being enough

A 1920×1080 ARGB frame is 8.3 MB; 3840×2160 is 33.2 MB. A single full-frame copy is
bandwidth-bound: ~0.5-1 ms at 1080p, ~2-4 ms at 4K on this machine. Compositing *n*
overlapping windows adds roughly *n* × the overlapping area, which is why damage tracking
and opaque-region optimisation matter more than micro-optimising the blitter.

The mitigation ladder, in the order it will be needed:

1. Damage regions + buffer age (do this first; it is worth 5-10× on typical desktops).
2. Opaque-region culling: skip pixels covered by an opaque surface above them.
3. Skip redundant frames when nothing changed and no client asked for a callback.
4. `PIXMAN_OP_SRC` for bottom-most opaque surfaces.
5. Move to the GL renderer for the composited scene, keeping shm for clients that only
   produce shm buffers (texture upload from the mapping, which is a fast path on integrated
   GPUs sharing memory).
6. Direct scanout for fullscreen clients (bypasses compositing entirely).
7. Blur/effects only with the GL renderer, and only at a reduced resolution.

## 11. GC discipline

The renderer and the input path are the two places where a GC pause is visible. Rules:

- No allocation per frame per surface. Reuse per-renderer scratch regions, matrices and
  clip arrays.
- `dynamic-extent` for argument vectors and temporary structs; `with-pinned-objects` only
  where CFFI needs it (small, rare).
- Damage regions are preallocated `pixman_region32_t` per output and per surface, cleared
  rather than re-created.
- Hot-path functions are compiled with `(optimize (speed 3) (safety 1))` and are periodically
  checked for new consing with `sb-ext:get-bytes-consed` around a scripted interaction.
- Benchmarks in `tests/perf/` assert: bytes consed per frame, per pointer motion, and per
  commit are all **zero** in steady state, and the build fails on regression.

/* SPDX-FileCopyrightText: 2026 Edgar Denny
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * wayland-move-client.c -- the phase-3d gate client: a window that asks to be
 * moved and resized.
 *
 * A real libwayland client with its own xdg-shell implementation.  It maps a
 * toplevel, draws a solid colour into it, and then does what a window with a
 * titlebar does: on a left button press it calls xdg_toplevel.move(seat, serial)
 * with the serial the compositor gave it, and on a right button press it calls
 * xdg_toplevel.resize(seat, serial, bottom_right).  It prints what it sent and
 * every configure it received, so the gate can assert the compositor's side of
 * the interaction from the *client's* side of the wire:
 *
 *   the serial it echoed is one the compositor issued (it came from a real
 *   button event, not from a guess);
 *   the resize became a configure carrying the size the drag asked for.
 *
 * Like the other fixtures here it is the peer, not the product: it links
 * libwayland-client on purpose (D1 applies to what we ship).
 */

#define _GNU_SOURCE

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

#define DEFAULT_WIDTH 200
#define DEFAULT_HEIGHT 150
#define BUFFER_STRIDE(width) ((width) * 4)
#define BUFFER_SIZE(width, height) (BUFFER_STRIDE(width) * (height))
#define WINDOW_COLOUR 0xFF3C8C3Cu /* premultiplied, opaque green-ish */

static struct wl_display *display;
static struct wl_registry *registry;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct wl_seat *seat;
static struct wl_pointer *pointer;
static struct wl_surface *surface;
static struct xdg_wm_base *wm_base;
static struct xdg_surface *xdg_surface;
static struct xdg_toplevel *toplevel;
static struct wl_buffer *buffer;

static int width = DEFAULT_WIDTH;
static int height = DEFAULT_HEIGHT;
static int mapped;
static int failed;

/* ------------------------------------------------------------------------- */
/* Shared memory                                                             */
/* ------------------------------------------------------------------------- */

static int create_pool_file(size_t size)
{
	int fd = memfd_create("cl-wayland-move-client", MFD_CLOEXEC);
	if (fd < 0) {
		fprintf(stderr, "FAIL: memfd_create: %s\n", strerror(errno));
		return -1;
	}
	if (ftruncate(fd, (off_t)size) < 0) {
		fprintf(stderr, "FAIL: ftruncate: %s\n", strerror(errno));
		close(fd);
		return -1;
	}
	return fd;
}

static int fill_buffer(int fd, int w, int h)
{
	size_t size = BUFFER_SIZE(w, h);
	uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (pixels == MAP_FAILED) {
		fprintf(stderr, "FAIL: mmap: %s\n", strerror(errno));
		return -1;
	}
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			pixels[y * w + x] = WINDOW_COLOUR;
		}
	}
	munmap(pixels, size);
	return 0;
}

static int make_buffer(void)
{
	int w = width, h = height;
	size_t size = BUFFER_SIZE(w, h);
	int fd = create_pool_file(size);
	if (fd < 0)
		return -1;
	if (fill_buffer(fd, w, h) < 0) {
		close(fd);
		return -1;
	}
	struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
	buffer = wl_shm_pool_create_buffer(pool, 0, w, h, BUFFER_STRIDE(w),
					   WL_SHM_FORMAT_ARGB8888);
	wl_shm_pool_destroy(pool);
	close(fd);
	return buffer ? 0 : -1;
}

static void draw(void)
{
	if (!buffer)
		return;
	wl_surface_attach(surface, buffer, 0, 0);
	wl_surface_damage(surface, 0, 0, width, height);
	wl_surface_commit(surface);
}

/* ------------------------------------------------------------------------- */
/* xdg-shell                                                                 */
/* ------------------------------------------------------------------------- */

static void wm_base_ping(void *data, struct xdg_wm_base *base, uint32_t serial)
{
	(void)data;
	xdg_wm_base_pong(base, serial);
}

static const struct xdg_wm_base_listener wm_base_listener = {
	.ping = wm_base_ping,
};

static void surface_configure(void *data, struct xdg_surface *surface, uint32_t serial)
{
	(void)data;
	/* The first configure is the compositor's "draw something"; every later one
	 * is a size change (a resize) or a state change (focus). */
	xdg_surface_ack_configure(surface, serial);
	if (!mapped) {
		mapped = 1;
		if (make_buffer() < 0) {
			failed = 1;
			return;
		}
		printf("mapped %dx%d\n", width, height);
		fflush(stdout);
	}
	draw();
}

static const struct xdg_surface_listener surface_listener = {
	.configure = surface_configure,
};

static void toplevel_configure(void *data, struct xdg_toplevel *t, int32_t w, int32_t h,
			       struct wl_array *states)
{
	(void)data;
	(void)t;
	(void)states;
	printf("configure %dx%d\n", (int)w, (int)h);
	fflush(stdout);
	/* A size the compositor asked for is the size to draw.  A move grab sends no
	 * configure; a resize grab does, and this is the client agreeing to it. */
	if (w > 0 && h > 0) {
		width = w;
		height = h;
	}
}

static void toplevel_close(void *data, struct xdg_toplevel *t)
{
	(void)data;
	(void)t;
	printf("close\n");
	fflush(stdout);
}

static const struct xdg_toplevel_listener toplevel_listener = {
	.configure = toplevel_configure,
	.close = toplevel_close,
};

/* ------------------------------------------------------------------------- */
/* Input                                                                     */
/* ------------------------------------------------------------------------- */

static uint32_t pointer_serial;
static int pointer_x, pointer_y;

static void pointer_enter(void *data, struct wl_pointer *p, uint32_t serial,
			  struct wl_surface *surface, wl_fixed_t x, wl_fixed_t y)
{
	(void)data;
	(void)p;
	(void)surface;
	pointer_serial = serial;
	pointer_x = wl_fixed_to_int(x);
	pointer_y = wl_fixed_to_int(y);
}

static void pointer_leave(void *data, struct wl_pointer *p, uint32_t serial,
			  struct wl_surface *surface)
{
	(void)data;
	(void)p;
	(void)serial;
	(void)surface;
}

static void pointer_motion(void *data, struct wl_pointer *p, uint32_t time,
			   wl_fixed_t x, wl_fixed_t y)
{
	(void)data;
	(void)p;
	(void)time;
	pointer_x = wl_fixed_to_int(x);
	pointer_y = wl_fixed_to_int(y);
}

static void pointer_button(void *data, struct wl_pointer *p, uint32_t serial,
			   uint32_t time, uint32_t button, uint32_t state)
{
	(void)data;
	(void)p;
	(void)time;
	pointer_serial = serial;
	printf("button %u %u %s\n", button, serial,
	       state == WL_POINTER_BUTTON_STATE_PRESSED ? "pressed" : "released");
	fflush(stdout);
	if (state != WL_POINTER_BUTTON_STATE_PRESSED)
		return;
	/* This is the request under test.  The serial is the one from our button
	 * event: a real capability, not a number we made up. */
	if (button == 0x110 && toplevel) {
		xdg_toplevel_move(toplevel, seat, serial);
		printf("move %u\n", serial);
		fflush(stdout);
	} else if (button == 0x111 && toplevel) {
		const uint32_t edges = XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM_RIGHT;
		xdg_toplevel_resize(toplevel, seat, serial, edges);
		printf("resize %u %u\n", serial, edges);
		fflush(stdout);
	}
}

static void pointer_axis(void *data, struct wl_pointer *p, uint32_t time,
			 uint32_t axis, wl_fixed_t value)
{
	(void)data;
	(void)p;
	(void)time;
	(void)axis;
	(void)value;
}

static const struct wl_pointer_listener pointer_listener = {
	.enter = pointer_enter,
	.leave = pointer_leave,
	.motion = pointer_motion,
	.button = pointer_button,
	.axis = pointer_axis,
};

/* ------------------------------------------------------------------------- */
/* Registry                                                                  */
/* ------------------------------------------------------------------------- */

static void seat_capabilities(void *data, struct wl_seat *s, uint32_t capabilities)
{
	(void)data;
	if ((capabilities & WL_SEAT_CAPABILITY_POINTER) && !pointer) {
		pointer = wl_seat_get_pointer(s);
		wl_pointer_add_listener(pointer, &pointer_listener, NULL);
	}
}

static void seat_name(void *data, struct wl_seat *s, const char *name)
{
	(void)data;
	(void)s;
	(void)name;
}

static const struct wl_seat_listener seat_listener = {
	.capabilities = seat_capabilities,
	.name = seat_name,
};

static void registry_global(void *data, struct wl_registry *reg, uint32_t name,
			    const char *interface, uint32_t version)
{
	(void)data;
	if (strcmp(interface, "wl_compositor") == 0 && !compositor) {
		compositor = wl_registry_bind(reg, name, &wl_compositor_interface,
					      version < 1 ? version : 1);
	} else if (strcmp(interface, "wl_shm") == 0 && !shm) {
		shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
	} else if (strcmp(interface, "xdg_wm_base") == 0 && !wm_base) {
		wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, 1);
		xdg_wm_base_add_listener(wm_base, &wm_base_listener, NULL);
	} else if (strcmp(interface, "wl_seat") == 0 && !seat) {
		seat = wl_registry_bind(reg, name, &wl_seat_interface, version < 4 ? version : 4);
		wl_seat_add_listener(seat, &seat_listener, NULL);
	}
}

static void registry_global_remove(void *data, struct wl_registry *reg, uint32_t name)
{
	(void)data;
	(void)reg;
	(void)name;
}

static const struct wl_registry_listener registry_listener = {
	.global = registry_global,
	.global_remove = registry_global_remove,
};

/* ------------------------------------------------------------------------- */

int main(int argc, char **argv)
{
	/* Line-buffered even when stdout is a pipe: the gate reads these lines as
	 * the evidence, and a client that buffers them until exit would deadlock the
	 * gate that is waiting for one. */
	setvbuf(stdout, NULL, _IOLBF, 0);

	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--width") == 0 && i + 1 < argc) {
			width = atoi(argv[++i]);
		} else if (strcmp(argv[i], "--height") == 0 && i + 1 < argc) {
			height = atoi(argv[++i]);
		}
	}
	if (width <= 0 || height <= 0) {
		fprintf(stderr, "FAIL: --width/--height must be positive\n");
		return 2;
	}

	display = wl_display_connect(NULL);
	if (!display) {
		fprintf(stderr, "FAIL: cannot connect: %s\n", strerror(errno));
		return 2;
	}

	registry = wl_display_get_registry(display);
	wl_registry_add_listener(registry, &registry_listener, NULL);
	if (wl_display_roundtrip(display) < 0) {
		fprintf(stderr, "FAIL: registry roundtrip\n");
		return 1;
	}
	if (!compositor || !shm || !wm_base || !seat) {
		fprintf(stderr, "FAIL: wl_compositor, wl_shm, xdg_wm_base and wl_seat "
				"must all be offered\n");
		return 1;
	}

	surface = wl_compositor_create_surface(compositor);
	xdg_surface = xdg_wm_base_get_xdg_surface(wm_base, surface);
	xdg_surface_add_listener(xdg_surface, &surface_listener, NULL);
	toplevel = xdg_surface_get_toplevel(xdg_surface);
	xdg_toplevel_add_listener(toplevel, &toplevel_listener, NULL);
	xdg_toplevel_set_title(toplevel, "move-client");
	xdg_toplevel_set_app_id(toplevel, "org.example.move-client");
	/* The initial commit with no buffer: this is what asks for a configure. */
	wl_surface_commit(surface);

	while (!failed) {
		if (wl_display_dispatch(display) < 0) {
			int err = wl_display_get_error(display);
			fprintf(stderr, "FAIL: dispatch: %s (protocol error %d: %s)\n",
				strerror(errno), err, strerror(err));
			return 1;
		}
	}

	return 1;
}

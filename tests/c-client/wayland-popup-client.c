/* SPDX-FileCopyrightText: 2026 Edgar Denny
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * wayland-popup-client.c -- the popup gate client: a window that opens menus.
 *
 * A real libwayland client with its own xdg-shell implementation.  It maps a
 * toplevel, draws a solid colour into it and paints its popups another colour, so
 * the gate can tell from the pixels alone which surface is on screen and where.
 * On each left-button press it opens a popup the way a menu does:
 *
 *   xdg_wm_base.create_positioner -> set_size / set_anchor_rect / set_anchor /
 *   set_gravity / set_constraint_adjustment -> xdg_surface.get_popup ->
 *   xdg_popup.grab(seat, serial) -> commit -> (configure) -> ack -> attach.
 *
 * By default each press opens the same menu in the same place, which is what the
 * gate needs: two presses, two anchors -- the plain case (no adjustment needed) and
 * the constrained one, where the requested place is off the output and the
 * compositor has to flip or slide it back.  With --follow-pointer the menu is
 * anchored at the pointer instead, 1x1, which is what a menu in a real application
 * does and what makes the manual demo (scripts/popup-demo.sh) behave like one.  The
 * client prints every configure it receives; the gate asserts the compositor's side
 * from its own state and the pixels, and reads these lines only in the log.
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

#define TOPLEVEL_WIDTH 300
#define TOPLEVEL_HEIGHT 200
#define POPUP_WIDTH 120
#define POPUP_HEIGHT 80
#define BUFFER_STRIDE(width) ((width) * 4)
#define BUFFER_SIZE(width, height) (BUFFER_STRIDE(width) * (height))
#define TOPLEVEL_COLOUR 0xFF3C8C3Cu /* premultiplied, opaque green-ish */
#define POPUP_COLOUR 0xFFCC33CCu    /* premultiplied, opaque magenta */

static struct wl_display *display;
static struct wl_registry *registry;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct wl_seat *seat;
static struct wl_pointer *pointer;
static struct xdg_wm_base *wm_base;

static struct wl_surface *toplevel_surface;
static struct xdg_surface *toplevel_xdg_surface;
static struct xdg_toplevel *toplevel;
static struct wl_buffer *toplevel_buffer;

static struct wl_surface *popup_surface;
static struct xdg_surface *popup_xdg_surface;
static struct xdg_popup *popup;
static struct wl_buffer *popup_buffer;
static int popup_width = POPUP_WIDTH;
static int popup_height = POPUP_HEIGHT;
static int popup_configured;
static int popup_count;

static int mapped;
static int failed;
static int follow_pointer;   /* --follow-pointer: anchor the menu at the pointer */
static int pointer_x;
static int pointer_y;

/* The two menus this client knows how to open.  Index 1 is deliberately placed
 * where a 320x240 output cannot show it, so the compositor must constrain it. */
struct popup_spec {
	int anchor_x;
	int anchor_y;
	int anchor_width;
	int anchor_height;
};

static const struct popup_spec popup_specs[] = {
	{ 10, 10, 20, 20 },   /* plain: fits where it was asked for */
	{ 290, 190, 10, 10 }, /* at the window's corner: needs a flip or a slide */
};

/* ------------------------------------------------------------------------- */
/* Shared memory                                                             */
/* ------------------------------------------------------------------------- */

static int create_pool_file(size_t size)
{
	int fd = memfd_create("cl-wayland-popup-client", MFD_CLOEXEC);
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

static struct wl_buffer *make_buffer(int w, int h, uint32_t colour)
{
	size_t size = (size_t)BUFFER_SIZE(w, h);
	int fd = create_pool_file(size);
	if (fd < 0)
		return NULL;
	uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (pixels == MAP_FAILED) {
		fprintf(stderr, "FAIL: mmap: %s\n", strerror(errno));
		close(fd);
		return NULL;
	}
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			pixels[y * w + x] = colour;
		}
	}
	munmap(pixels, size);

	struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
	struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, w, h,
							    BUFFER_STRIDE(w),
							    WL_SHM_FORMAT_ARGB8888);
	wl_shm_pool_destroy(pool);
	close(fd);
	return buffer;
}

/* ------------------------------------------------------------------------- */
/* The toplevel                                                              */
/* ------------------------------------------------------------------------- */

static void wm_base_ping(void *data, struct xdg_wm_base *base, uint32_t serial)
{
	(void)data;
	xdg_wm_base_pong(base, serial);
}

static const struct xdg_wm_base_listener wm_base_listener = {
	.ping = wm_base_ping,
};

static void toplevel_surface_configure(void *data, struct xdg_surface *surface,
				       uint32_t serial)
{
	(void)data;
	xdg_surface_ack_configure(surface, serial);
	if (!mapped) {
		mapped = 1;
		toplevel_buffer = make_buffer(TOPLEVEL_WIDTH, TOPLEVEL_HEIGHT, TOPLEVEL_COLOUR);
		if (!toplevel_buffer) {
			failed = 1;
			return;
		}
		printf("mapped %dx%d\n", TOPLEVEL_WIDTH, TOPLEVEL_HEIGHT);
		fflush(stdout);
	}
	wl_surface_attach(toplevel_surface, toplevel_buffer, 0, 0);
	wl_surface_damage(toplevel_surface, 0, 0, TOPLEVEL_WIDTH, TOPLEVEL_HEIGHT);
	wl_surface_commit(toplevel_surface);
}

static const struct xdg_surface_listener toplevel_surface_listener = {
	.configure = toplevel_surface_configure,
};

static void toplevel_configure(void *data, struct xdg_toplevel *t, int32_t w, int32_t h,
			       struct wl_array *states)
{
	(void)data;
	(void)t;
	(void)h;
	(void)states;
	printf("toplevel-configure %dx%d\n", (int)w, (int)h);
	fflush(stdout);
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
/* The popup                                                                 */
/* ------------------------------------------------------------------------- */

static void popup_configure(void *data, struct xdg_popup *p, int32_t x, int32_t y,
			    int32_t w, int32_t h)
{
	(void)data;
	(void)p;
	popup_width = (int)w;
	popup_height = (int)h;
	printf("popup-configure %d %d %d %d\n", (int)x, (int)y, (int)w, (int)h);
	fflush(stdout);
}

static void popup_done(void *data, struct xdg_popup *p)
{
	(void)data;
	printf("popup-done\n");
	fflush(stdout);
	/* The compositor has taken it off the screen; the client's half is to
	 * destroy the objects in the order the protocol requires. */
	xdg_popup_destroy(p);
	popup = NULL;
	xdg_surface_destroy(popup_xdg_surface);
	popup_xdg_surface = NULL;
	wl_surface_destroy(popup_surface);
	popup_surface = NULL;
	if (popup_buffer) {
		wl_buffer_destroy(popup_buffer);
		popup_buffer = NULL;
	}
	popup_configured = 0;
	popup_count++;
}

static const struct xdg_popup_listener popup_listener = {
	.configure = popup_configure,
	.popup_done = popup_done,
};

static void popup_surface_configure(void *data, struct xdg_surface *surface,
				    uint32_t serial)
{
	(void)data;
	xdg_surface_ack_configure(surface, serial);
	if (!popup_configured) {
		popup_configured = 1;
		popup_buffer = make_buffer(popup_width, popup_height, POPUP_COLOUR);
		if (!popup_buffer) {
			failed = 1;
			return;
		}
	}
	wl_surface_attach(popup_surface, popup_buffer, 0, 0);
	wl_surface_damage(popup_surface, 0, 0, popup_width, popup_height);
	wl_surface_commit(popup_surface);
}

static const struct xdg_surface_listener popup_surface_listener = {
	.configure = popup_surface_configure,
};

static void open_popup(uint32_t serial)
{
	/* A menu belongs where the pointer is: a 1x1 anchor rectangle at the click,
	 * which the compositor is then free to keep inside the output.  Clamped to
	 * the window, because the anchor rectangle may not extend outside the
	 * parent's window geometry. */
	struct popup_spec pointer_spec = {
		pointer_x < 0 ? 0 : (pointer_x >= TOPLEVEL_WIDTH ? TOPLEVEL_WIDTH - 1 : pointer_x),
		pointer_y < 0 ? 0 : (pointer_y >= TOPLEVEL_HEIGHT ? TOPLEVEL_HEIGHT - 1 : pointer_y),
		1,
		1,
	};
	const struct popup_spec *spec = follow_pointer ? &pointer_spec
						      : &popup_specs[popup_count % 2];
	struct xdg_positioner *positioner = xdg_wm_base_create_positioner(wm_base);

	xdg_positioner_set_size(positioner, POPUP_WIDTH, POPUP_HEIGHT);
	xdg_positioner_set_anchor_rect(positioner, spec->anchor_x, spec->anchor_y,
				       spec->anchor_width, spec->anchor_height);
	xdg_positioner_set_anchor(positioner, XDG_POSITIONER_ANCHOR_BOTTOM_RIGHT);
	xdg_positioner_set_gravity(positioner, XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT);
	xdg_positioner_set_constraint_adjustment(positioner,
						 XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_X |
						 XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_Y |
						 XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_X |
						 XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_Y);

	popup_surface = wl_compositor_create_surface(compositor);
	popup_xdg_surface = xdg_wm_base_get_xdg_surface(wm_base, popup_surface);
	xdg_surface_add_listener(popup_xdg_surface, &popup_surface_listener, NULL);
	popup = xdg_surface_get_popup(popup_xdg_surface, toplevel_xdg_surface, positioner);
	xdg_popup_add_listener(popup, &popup_listener, NULL);
	xdg_positioner_destroy(positioner);

	/* The serial of the press that asked for the menu: an explicit grab is only
	 * meaningful while that interaction is the one going on. */
	xdg_popup_grab(popup, seat, serial);
	printf("popup %d grab %u\n", popup_count % 2, serial);
	fflush(stdout);

	/* The initial commit with no buffer: this is what asks for the placement. */
	wl_surface_commit(popup_surface);
}

/* ------------------------------------------------------------------------- */
/* Input                                                                     */
/* ------------------------------------------------------------------------- */

static void pointer_enter(void *data, struct wl_pointer *p, uint32_t serial,
			  struct wl_surface *surface, wl_fixed_t x, wl_fixed_t y)
{
	(void)data;
	(void)p;
	(void)serial;
	(void)surface;
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
	printf("button %u %u %s\n", button, serial,
	       state == WL_POINTER_BUTTON_STATE_PRESSED ? "pressed" : "released");
	fflush(stdout);
	if (state != WL_POINTER_BUTTON_STATE_PRESSED)
		return;
	if (button == 0x110 && toplevel && !popup)
		open_popup(serial);
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
					      version < 3 ? version : 3);
	} else if (strcmp(interface, "wl_shm") == 0 && !shm) {
		shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
	} else if (strcmp(interface, "xdg_wm_base") == 0 && !wm_base) {
		wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, 1);
		xdg_wm_base_add_listener(wm_base, &wm_base_listener, NULL);
	} else if (strcmp(interface, "wl_seat") == 0 && !seat) {
		seat = wl_registry_bind(reg, name, &wl_seat_interface,
					version < 4 ? version : 4);
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
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--follow-pointer") == 0)
			follow_pointer = 1;
	}

	/* Line-buffered even when stdout is a pipe: the gate reads these lines as
	 * the evidence, and a client that buffered them until exit would look like a
	 * hang. */
	setvbuf(stdout, NULL, _IOLBF, 0);

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

	toplevel_surface = wl_compositor_create_surface(compositor);
	toplevel_xdg_surface = xdg_wm_base_get_xdg_surface(wm_base, toplevel_surface);
	xdg_surface_add_listener(toplevel_xdg_surface, &toplevel_surface_listener, NULL);
	toplevel = xdg_surface_get_toplevel(toplevel_xdg_surface);
	xdg_toplevel_add_listener(toplevel, &toplevel_listener, NULL);
	xdg_toplevel_set_title(toplevel, "popup-client");
	xdg_toplevel_set_app_id(toplevel, "org.example.popup-client");
	wl_surface_commit(toplevel_surface);

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

/* SPDX-FileCopyrightText: 2026 Edgar Denny
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * wayland-shm-client.c -- the phase-2a gate client.
 *
 * A real libwayland client that draws through wl_shm and nothing else: no
 * xdg-shell, no wl_shell, no toolkit.  It writes a known pattern into a
 * shared-memory buffer, attaches it at a known position, damages it, asks for a
 * frame callback, commits, and exits 0 only when the callback arrives -- so a
 * passing run proves the server mapped our file, validated the buffer, applied
 * the commit, rendered it, and fired frame callbacks after presenting, not at
 * commit time.
 *
 * Pattern: a 64x32 ARGB8888 buffer, left half opaque red, right half opaque blue,
 * attached at (10, 20) on a 256x256 output.  The gate reads those pixels back out
 * of the target.
 *
 * Like wayland-probe.c this is the *peer*, not the product: it links
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

#define BUFFER_WIDTH 64
#define BUFFER_HEIGHT 32
#define BUFFER_STRIDE (BUFFER_WIDTH * 4)
#define BUFFER_SIZE (BUFFER_STRIDE * BUFFER_HEIGHT)
#define ATTACH_X 10
#define ATTACH_Y 20

static struct wl_display *display;
static struct wl_registry *registry;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static int got_frame_callback;

static void frame_done(void *data, struct wl_callback *callback, uint32_t time)
{
	(void)data;
	(void)time;
	got_frame_callback = 1;
	wl_callback_destroy(callback);
}

static const struct wl_callback_listener frame_listener = {
	.done = frame_done,
};

static void registry_global(void *data, struct wl_registry *reg, uint32_t name,
			    const char *interface, uint32_t version)
{
	(void)data;
	if (strcmp(interface, "wl_compositor") == 0 && !compositor)
		compositor = wl_registry_bind(reg, name, &wl_compositor_interface,
					      version < 1 ? version : 1);
	else if (strcmp(interface, "wl_shm") == 0 && !shm)
		shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
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

static int create_pool_file(void)
{
	int fd = memfd_create("cl-wayland-shm-client", MFD_CLOEXEC);
	if (fd < 0) {
		fprintf(stderr, "FAIL: memfd_create: %s\n", strerror(errno));
		return -1;
	}
	if (ftruncate(fd, BUFFER_SIZE) < 0) {
		fprintf(stderr, "FAIL: ftruncate: %s\n", strerror(errno));
		close(fd);
		return -1;
	}
	return fd;
}

static int fill_pattern(int fd)
{
	uint32_t *pixels = mmap(NULL, BUFFER_SIZE, PROT_READ | PROT_WRITE,
				MAP_SHARED, fd, 0);
	if (pixels == MAP_FAILED) {
		fprintf(stderr, "FAIL: mmap: %s\n", strerror(errno));
		return -1;
	}
	for (int row = 0; row < BUFFER_HEIGHT; row++) {
		for (int column = 0; column < BUFFER_WIDTH; column++) {
			/* Premultiplied ARGB, opaque: red on the left, blue on the right. */
			pixels[row * BUFFER_WIDTH + column] =
				column < BUFFER_WIDTH / 2 ? 0xFFFF0000u : 0xFF0000FFu;
		}
	}
	munmap(pixels, BUFFER_SIZE);
	return 0;
}

int main(void)
{
	struct wl_surface *surface;
	struct wl_shm_pool *pool;
	struct wl_buffer *buffer;
	struct wl_callback *callback;
	int fd;

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
	if (!compositor || !shm) {
		fprintf(stderr, "FAIL: wl_compositor and wl_shm must both be offered\n");
		return 1;
	}

	fd = create_pool_file();
	if (fd < 0)
		return 1;
	if (fill_pattern(fd) < 0)
		return 1;

	pool = wl_shm_create_pool(shm, fd, BUFFER_SIZE);
	buffer = wl_shm_pool_create_buffer(pool, 0, BUFFER_WIDTH, BUFFER_HEIGHT,
					   BUFFER_STRIDE, WL_SHM_FORMAT_ARGB8888);
	wl_shm_pool_destroy(pool);
	/* libwayland duplicated the descriptor when it queued it for sending, so the
	 * buffer keeps its own reference and closing ours changes nothing.  This also
	 * exercises the server's rule that a pool may die before its buffer is used. */
	close(fd);

	surface = wl_compositor_create_surface(compositor);
	wl_surface_attach(surface, buffer, ATTACH_X, ATTACH_Y);
	wl_surface_damage(surface, 0, 0, BUFFER_WIDTH, BUFFER_HEIGHT);
	callback = wl_surface_frame(surface);
	wl_callback_add_listener(callback, &frame_listener, NULL);
	wl_surface_commit(surface);

	/* Dispatch until the frame callback arrives; a compositor that never
	 * presents, or presents without firing callbacks, fails here. */
	int ret = 0;
	while (!got_frame_callback) {
		if (wl_display_dispatch(display) < 0) {
			fprintf(stderr, "FAIL: dispatch: %s\n", strerror(errno));
			ret = 1;
			break;
		}
	}

	if (wl_display_get_error(display) != 0) {
		fprintf(stderr, "FAIL: protocol error %d: %s\n",
			(int)wl_display_get_error(display), strerror(errno));
		ret = 1;
	}

	printf("drew %dx%d at %d,%d, frame callback received: %s\n",
	       BUFFER_WIDTH, BUFFER_HEIGHT, ATTACH_X, ATTACH_Y,
	       got_frame_callback ? "yes" : "no");
	if (!got_frame_callback)
		ret = 1;

	wl_display_disconnect(display);
	if (ret == 0)
		printf("wayland-shm-client: all checks passed\n");
	return ret;
}

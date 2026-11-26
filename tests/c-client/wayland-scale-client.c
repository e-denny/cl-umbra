/* SPDX-FileCopyrightText: 2026 Edgar Denny
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * wayland-scale-client.c -- the phase-2b gate client.
 *
 * A real libwayland client that draws one four-coloured buffer through wl_shm,
 * with a buffer scale and a buffer transform it chooses on the command line, and
 * exits 0 only when its frame callback arrives.  The gate then reads the frame back
 * and checks that each quadrant landed where the scale and the transform say it
 * should -- which is the part a compositor can get wrong in eight different ways.
 *
 * The buffer is its own size (--buffer, default 64x32); --scale is what the client
 * tells the compositor to divide it by, and --transform is one of wl_output's
 * eight.  Quadrants, clockwise from the top left: opaque red, green, blue, white.
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

static struct wl_display *display;
static struct wl_registry *registry;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static int got_frame_callback;
static uint32_t compositor_version;

static int buffer_width = 64;
static int buffer_height = 32;
static int buffer_scale = 1;
static int buffer_transform = 0;
static int attach_x, attach_y;

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
	if (strcmp(interface, "wl_compositor") == 0 && !compositor) {
		compositor_version = version;
		compositor = wl_registry_bind(reg, name, &wl_compositor_interface,
					      version < 3 ? version : 3);
	} else if (strcmp(interface, "wl_shm") == 0 && !shm) {
		shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
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

static int create_shm_file(size_t size)
{
	int fd;
	char name[64];

	snprintf(name, sizeof(name), "wayland-scale-client-%d", getpid());
	fd = memfd_create(name, MFD_CLOEXEC);
	if (fd < 0) {
		perror("memfd_create");
		return -1;
	}
	if (ftruncate(fd, (off_t)size) < 0) {
		perror("ftruncate");
		close(fd);
		return -1;
	}
	return fd;
}

static uint32_t quadrant_colour(int x, int y)
{
	int left = x < buffer_width / 2;
	int top = y < buffer_height / 2;

	if (top)
		return left ? 0xFFFF0000u : 0xFF00FF00u;   /* red, green */
	return left ? 0xFF0000FFu : 0xFFFFFFFFu;            /* blue, white */
}

static void parse_size(const char *text)
{
	int width, height;

	if (sscanf(text, "%dx%d", &width, &height) == 2 && width > 0 && height > 0) {
		buffer_width = width;
		buffer_height = height;
		return;
	}
	fprintf(stderr, "not a size: %s (the form is WIDTHxHEIGHT)\n", text);
	exit(2);
}

static void parse_pair(const char *text)
{
	int x, y;

	if (sscanf(text, "%d,%d", &x, &y) == 2) {
		attach_x = x;
		attach_y = y;
		return;
	}
	fprintf(stderr, "not a position: %s (the form is X,Y)\n", text);
	exit(2);
}

int main(int argc, char **argv)
{
	struct wl_surface *surface;
	struct wl_buffer *buffer;
	struct wl_callback *callback;
	struct wl_shm_pool *pool;
	int stride, size, fd, i;
	uint32_t *pixels;
	void *mapping;

	for (i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--buffer") == 0 && i + 1 < argc)
			parse_size(argv[++i]);
		else if (strcmp(argv[i], "--scale") == 0 && i + 1 < argc)
			buffer_scale = atoi(argv[++i]);
		else if (strcmp(argv[i], "--transform") == 0 && i + 1 < argc)
			buffer_transform = atoi(argv[++i]);
		else if (strcmp(argv[i], "--attach") == 0 && i + 1 < argc)
			parse_pair(argv[++i]);
		else {
			fprintf(stderr, "unknown option: %s\n", argv[i]);
			return 2;
		}
	}
	if (buffer_scale < 1) {
		fprintf(stderr, "scale must be at least 1\n");
		return 2;
	}

	display = wl_display_connect(NULL);
	if (!display) {
		fprintf(stderr, "no display: %s\n", getenv("WAYLAND_DISPLAY"));
		return 1;
	}
	registry = wl_display_get_registry(display);
	wl_registry_add_listener(registry, &registry_listener, NULL);
	wl_display_roundtrip(display);
	if (!compositor || !shm) {
		fprintf(stderr, "the compositor offers no wl_compositor and wl_shm\n");
		return 1;
	}

	stride = buffer_width * 4;
	size = stride * buffer_height;
	fd = create_shm_file((size_t)size);
	if (fd < 0)
		return 1;
	mapping = mmap(NULL, (size_t)size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (mapping == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	pixels = mapping;
	for (int y = 0; y < buffer_height; y++)
		for (int x = 0; x < buffer_width; x++)
			pixels[y * buffer_width + x] = quadrant_colour(x, y);

	pool = wl_shm_create_pool(shm, fd, size);
	buffer = wl_shm_pool_create_buffer(pool, 0, buffer_width, buffer_height,
					   stride, WL_SHM_FORMAT_ARGB8888);
	wl_shm_pool_destroy(pool);
	close(fd);

	surface = wl_compositor_create_surface(compositor);
	if (buffer_scale != 1) {
		if (compositor_version < 3) {
			fprintf(stderr, "buffer scale needs wl_compositor v3, got v%u\n",
				compositor_version);
			return 1;
		}
		wl_surface_set_buffer_scale(surface, buffer_scale);
	}
	if (buffer_transform != 0) {
		if (compositor_version < 2) {
			fprintf(stderr, "buffer transform needs wl_compositor v2, got v%u\n",
				compositor_version);
			return 1;
		}
		wl_surface_set_buffer_transform(surface, buffer_transform);
	}

	wl_surface_attach(surface, buffer, attach_x, attach_y);
	wl_surface_damage(surface, 0, 0, buffer_width, buffer_height);
	callback = wl_surface_frame(surface);
	wl_callback_add_listener(callback, &frame_listener, NULL);
	wl_surface_commit(surface);

	printf("scale-client: buffer %dx%d at scale %d, transform %d, attach (%d,%d)\n",
	       buffer_width, buffer_height, buffer_scale, buffer_transform,
	       attach_x, attach_y);
	fflush(stdout);

	while (!got_frame_callback) {
		if (wl_display_dispatch(display) < 0) {
			fprintf(stderr, "the display connection failed before the frame\n");
			return 1;
		}
	}
	wl_display_roundtrip(display);
	wl_display_disconnect(display);
	return 0;
}

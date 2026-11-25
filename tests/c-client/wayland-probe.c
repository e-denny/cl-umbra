/* SPDX-FileCopyrightText: 2026 Edgar Denny
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * wayland-probe.c -- an independent C client for the phase-1 gate.
 *
 * This is the *peer*, not the product.  It is deliberately built against the
 * system's libwayland-client: everything else in this repository refuses to link
 * libwayland, and the point of this probe is that a real libwayland client --
 * its id allocation, its event queue, its proxy lifetime -- talks to our server
 * and gets answers it considers correct.  The purity rule (D1) applies to the
 * image we ship, not to a test fixture whose whole job is to be the other side.
 *
 * What it establishes, in order:
 *
 *   1. registry: both demo globals are announced, with the versions the server
 *      claims;
 *   2. wl_output at version 3 receives geometry, mode, scale and done, in the
 *      order the protocol asks for, and nothing after done;
 *   3. wl_output.release is answered with wl_display.delete_id, proven the only
 *      way a client can prove it: the released id is handed out again by a
 *      later bind.  If the server sent delete_id at the wrong time -- or never
 *      -- libwayland keeps the id as a tombstone and never reuses it.  (Which id
 *      comes back is libwayland's business: its client map reuses the most
 *      recently freed id, not the lowest, so the check is that the released id
 *      returns within a few binds, not that it returns immediately.);
 *   4. wl_output at version 1 receives geometry and mode and never done, scale,
 *      name or description -- the server gates events by the bound version;
 *   5. wl_compositor binds at version 1, round-trips, and can be destroyed
 *      locally (wl_compositor has no request before version 7);
 *   6. the display still round-trips at the end, with no protocol error queued.
 *
 * Exit status is the verdict: 0 all checks passed, 1 a check failed, 2 no
 * connection.
 */

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <wayland-client.h>

static int failures;

#define CHECK(condition, ...)                                                  \
	do {                                                                   \
		if (!(condition)) {                                            \
			failures++;                                            \
			fprintf(stderr, "FAIL: ");                             \
			fprintf(stderr, __VA_ARGS__);                          \
			fprintf(stderr, "\n");                                 \
		}                                                              \
	} while (0)

struct output_events {
	int geometry;
	int mode;
	int done;
	int scale;
	int name;
	int description;
	/* Order of arrival, as a string of first letters, for the ordering check. */
	char order[16];
	size_t order_length;
};

static void record(struct output_events *events, char letter)
{
	if (events->order_length + 1 < sizeof(events->order)) {
		events->order[events->order_length++] = letter;
		events->order[events->order_length] = '\0';
	}
}

static void output_geometry(void *data, struct wl_output *output, int32_t x,
			    int32_t y, int32_t physical_width, int32_t physical_height,
			    int32_t subpixel, const char *make, const char *model,
			    int32_t transform)
{
	struct output_events *events = data;
	(void)output;
	(void)x;
	(void)y;
	(void)physical_width;
	(void)physical_height;
	(void)subpixel;
	(void)make;
	(void)model;
	(void)transform;
	events->geometry++;
	record(events, 'g');
}

static void output_mode(void *data, struct wl_output *output, uint32_t flags,
			int32_t width, int32_t height, int32_t refresh)
{
	struct output_events *events = data;
	(void)output;
	(void)flags;
	(void)width;
	(void)height;
	(void)refresh;
	events->mode++;
	record(events, 'm');
}

static void output_done(void *data, struct wl_output *output)
{
	struct output_events *events = data;
	(void)output;
	events->done++;
	record(events, 'd');
}

static void output_scale(void *data, struct wl_output *output, int32_t factor)
{
	struct output_events *events = data;
	(void)output;
	(void)factor;
	events->scale++;
	record(events, 's');
}

static void output_name(void *data, struct wl_output *output, const char *name)
{
	struct output_events *events = data;
	(void)output;
	(void)name;
	events->name++;
	record(events, 'n');
}

static void output_description(void *data, struct wl_output *output,
			       const char *description)
{
	struct output_events *events = data;
	(void)output;
	(void)description;
	events->description++;
	record(events, 'D');
}

static const struct wl_output_listener output_listener = {
	.geometry = output_geometry,
	.mode = output_mode,
	.done = output_done,
	.scale = output_scale,
	.name = output_name,
	.description = output_description,
};

struct globals {
	uint32_t compositor_name;
	uint32_t compositor_version;
	uint32_t output_name;
	uint32_t output_version;
	int count;
};

static void registry_global(void *data, struct wl_registry *registry, uint32_t name,
			    const char *interface, uint32_t version)
{
	struct globals *globals = data;
	(void)registry;
	globals->count++;
	if (strcmp(interface, "wl_compositor") == 0) {
		globals->compositor_name = name;
		globals->compositor_version = version;
	} else if (strcmp(interface, "wl_output") == 0) {
		globals->output_name = name;
		globals->output_version = version;
	}
	printf("global %u: %s version %u\n", name, interface, version);
}

static void registry_global_remove(void *data, struct wl_registry *registry, uint32_t name)
{
	(void)data;
	(void)registry;
	(void)name;
}

static const struct wl_registry_listener registry_listener = {
	.global = registry_global,
	.global_remove = registry_global_remove,
};

static int roundtrip(struct wl_display *display, const char *what)
{
	if (wl_display_roundtrip(display) < 0) {
		failures++;
		fprintf(stderr, "FAIL: roundtrip after %s failed: %s\n", what,
			strerror(errno));
		return -1;
	}
	return 0;
}

int main(void)
{
	struct wl_display *display;
	struct wl_registry *registry;
	struct globals globals = {0};
	struct output_events at_three = {0};
	struct output_events at_one = {0};
	struct wl_output *output;
	struct wl_compositor *compositor;
	uint32_t released_id;
	uint32_t rebound_id;

	display = wl_display_connect(NULL);
	if (!display) {
		fprintf(stderr, "FAIL: cannot connect: %s\n", strerror(errno));
		return 2;
	}

	registry = wl_display_get_registry(display);
	wl_registry_add_listener(registry, &registry_listener, &globals);
	if (roundtrip(display, "get_registry") < 0)
		return 1;

	CHECK(globals.count == 2, "expected exactly 2 globals, saw %d", globals.count);
	CHECK(globals.compositor_name != 0, "wl_compositor was not announced");
	CHECK(globals.output_name != 0, "wl_output was not announced");
	CHECK(globals.compositor_version >= 1, "wl_compositor version %u",
	      globals.compositor_version);
	CHECK(globals.output_version >= 4, "wl_output version %u is older than expected",
	      globals.output_version);

	/* --- wl_output at version 3: full initial events, then release --------- */
	output = wl_registry_bind(registry, globals.output_name, &wl_output_interface, 3);
	CHECK(output != NULL, "bind wl_output at version 3");
	if (!output)
		return 1;
	wl_output_add_listener(output, &output_listener, &at_three);
	if (roundtrip(display, "bind wl_output v3") < 0)
		return 1;

	CHECK(at_three.geometry == 1, "geometry events at v3: %d", at_three.geometry);
	CHECK(at_three.mode == 1, "mode events at v3: %d", at_three.mode);
	CHECK(at_three.scale == 1, "scale events at v3: %d", at_three.scale);
	CHECK(at_three.done == 1, "done events at v3: %d", at_three.done);
	/* geometry, mode, scale, then done last (docs/protocol-layer.md §8). */
	CHECK(strcmp(at_three.order, "gmsd") == 0,
	      "event order at v3 was '%s', expected geometry, mode, scale, done",
	      at_three.order);
	printf("wl_output v3: geometry %d, mode %d, scale %d, done %d, order '%s'\n",
	       at_three.geometry, at_three.mode, at_three.scale, at_three.done,
	       at_three.order);

	released_id = wl_proxy_get_id((struct wl_proxy *)output);
	wl_output_release(output);
	if (roundtrip(display, "wl_output.release") < 0)
		return 1;

	/* --- the released id comes back: proof that delete_id arrived ---------- */
	rebound_id = 0;
	for (int attempt = 0; attempt < 8 && rebound_id != released_id; attempt++) {
		output = wl_registry_bind(registry, globals.output_name,
					  &wl_output_interface, 3);
		if (!output) {
			failures++;
			fprintf(stderr, "FAIL: rebind attempt %d\n", attempt + 1);
			return 1;
		}
		rebound_id = wl_proxy_get_id((struct wl_proxy *)output);
		if (roundtrip(display, "rebind wl_output") < 0)
			return 1;
		wl_output_release(output);
		if (roundtrip(display, "release rebound wl_output") < 0)
			return 1;
	}

	CHECK(rebound_id == released_id,
	      "the released id %u never came back within 8 binds (last was %u); "
	      "wl_display.delete_id did not arrive, so the client still holds a "
	      "tombstone for it",
	      released_id, rebound_id);
	printf("id reuse: released %u, came back as %u\n", released_id, rebound_id);

	/* --- wl_output at version 1: no newer events --------------------------- */
	output = wl_registry_bind(registry, globals.output_name, &wl_output_interface, 1);
	CHECK(output != NULL, "bind wl_output at version 1");
	if (!output)
		return 1;
	wl_output_add_listener(output, &output_listener, &at_one);
	if (roundtrip(display, "bind wl_output v1") < 0)
		return 1;

	CHECK(at_one.geometry == 1, "geometry events at v1: %d", at_one.geometry);
	CHECK(at_one.mode == 1, "mode events at v1: %d", at_one.mode);
	CHECK(at_one.done == 0, "wl_output.done reached a version-1 object: %d",
	      at_one.done);
	CHECK(at_one.scale == 0, "wl_output.scale reached a version-1 object: %d",
	      at_one.scale);
	CHECK(at_one.name == 0, "wl_output.name reached a version-1 object: %d",
	      at_one.name);
	CHECK(at_one.description == 0,
	      "wl_output.description reached a version-1 object: %d",
	      at_one.description);
	printf("wl_output v1: geometry %d, mode %d, done %d (must be 0)\n",
	       at_one.geometry, at_one.mode, at_one.done);

	/* --- wl_compositor: bind, roundtrip, local destroy --------------------- */
	compositor = wl_registry_bind(registry, globals.compositor_name,
				      &wl_compositor_interface, 1);
	CHECK(compositor != NULL, "bind wl_compositor at version 1");
	if (compositor) {
		if (roundtrip(display, "bind wl_compositor") < 0)
			return 1;
		printf("wl_compositor bound at version 1 as id %u\n",
		       wl_proxy_get_id((struct wl_proxy *)compositor));
		/* No request exists below version 7; this releases the proxy only,
		 * and the server cleans the resource up at disconnect. */
		wl_compositor_destroy(compositor);
	}

	/* --- still healthy ---------------------------------------------------- */
	if (roundtrip(display, "final") < 0)
		return 1;
	CHECK(wl_display_get_error(display) == 0,
	      "the display has a protocol error queued after a clean run");

	wl_display_disconnect(display);

	if (failures) {
		fprintf(stderr, "wayland-probe: %d check(s) failed\n", failures);
		return 1;
	}
	printf("wayland-probe: all checks passed\n");
	return 0;
}

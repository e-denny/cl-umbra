/* SPDX-FileCopyrightText: 2026 Edgar Denny
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Parse a keymap with the system's libxkbcommon and translate evdev keycodes.
 *
 * This is the peer, not the product: our compositor generates the XKB keymap
 * text itself and links nothing (D28), so the only way to know whether what we
 * send is *parseable by a client* is to parse it with a client's parser.  Same
 * reasoning as the libwayland fixtures next door.
 *
 *   xkb-keymap-probe KEYMAP-FILE [EVDEV-KEYCODE...]
 *
 * Checks, in order:
 *   1. the keymap parses with NO_DEFAULT_INCLUDES, i.e. it stands alone;
 *   2. every given evdev keycode has a keysym at level 0 and (if the key has
 *      one) at level 1 -- the level a held Shift selects;
 *   3. Shift_L followed by Q gives "Q": the compatibility `interpret` rules and
 *      the two-level types actually take effect in a client's xkb state, which
 *      is the part a keymap that merely parses can still get wrong.
 *
 * Exits 0 only if all three hold.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <xkbcommon/xkbcommon.h>
#include <xkbcommon/xkbcommon-keysyms.h>

static char *read_file(const char *path)
{
	FILE *file = fopen(path, "rb");
	long size;
	char *text;

	if (!file) {
		fprintf(stderr, "xkb-probe: cannot open %s\n", path);
		return NULL;
	}
	if (fseek(file, 0, SEEK_END) != 0 || (size = ftell(file)) < 0 ||
	    fseek(file, 0, SEEK_SET) != 0) {
		fclose(file);
		return NULL;
	}
	text = calloc((size_t)size + 1, 1);
	if (text && fread(text, 1, (size_t)size, file) != (size_t)size) {
		free(text);
		text = NULL;
	}
	fclose(file);
	return text;
}

static void syms_name(struct xkb_keymap *keymap, xkb_keycode_t code, int level,
		      char *name, size_t size)
{
	const xkb_keysym_t *syms = NULL;
	int count = xkb_keymap_key_get_syms_by_level(keymap, code, 0, level, &syms);

	if (count < 1 || xkb_keysym_get_name(syms[0], name, size) < 0) {
		snprintf(name, size, "(none)");
	}
}

int main(int argc, char **argv)
{
	struct xkb_context *context;
	struct xkb_keymap *keymap;
	struct xkb_state *state;
	char *text;
	char plain[80], shifted[80];
	int i, failures = 0;

	if (argc < 2) {
		fprintf(stderr, "usage: %s KEYMAP-FILE [EVDEV-KEYCODE...]\n", argv[0]);
		return 2;
	}

	text = read_file(argv[1]);
	if (!text) {
		return 2;
	}

	context = xkb_context_new(XKB_CONTEXT_NO_DEFAULT_INCLUDES |
				  XKB_CONTEXT_NO_ENVIRONMENT_NAMES);
	if (!context) {
		fprintf(stderr, "xkb-probe: no xkb context\n");
		free(text);
		return 2;
	}

	/* NO_DEFAULT_INCLUDES: the keymap must stand alone, with no lookup in
	 * /usr/share/X11/xkb.  That is the property our generator claims. */
	keymap = xkb_keymap_new_from_string(context, text, XKB_KEYMAP_FORMAT_TEXT_V1,
					    XKB_KEYMAP_COMPILE_NO_FLAGS);
	if (!keymap) {
		fprintf(stderr, "xkb-probe: the keymap did not parse\n");
		free(text);
		xkb_context_unref(context);
		return 1;
	}

	printf("keymap: parses standalone, keycodes %u..%u\n",
	       (unsigned)xkb_keymap_min_keycode(keymap),
	       (unsigned)xkb_keymap_max_keycode(keymap));

	for (i = 2; i < argc; i++) {
		/* wl_keyboard.key carries the evdev code; the client adds 8. */
		xkb_keycode_t code = (xkb_keycode_t)(atoi(argv[i]) + 8);

		syms_name(keymap, code, 0, plain, sizeof plain);
		syms_name(keymap, code, 1, shifted, sizeof shifted);
		if (strcmp(plain, "(none)") == 0) {
			printf("keycode %s -> MISSING\n", argv[i]);
			failures++;
			continue;
		}
		if (strcmp(plain, shifted) == 0) {
			printf("keycode %s -> %s\n", argv[i], plain);
		} else {
			printf("keycode %s -> %s (shift: %s)\n", argv[i], plain, shifted);
		}
	}

	/* The state test: Shift held while 'q' is pressed must give "Q". */
	state = xkb_state_new(keymap);
	if (!state) {
		fprintf(stderr, "xkb-probe: no xkb state\n");
		xkb_keymap_unref(keymap);
		xkb_context_unref(context);
		free(text);
		return 2;
	}
	xkb_state_update_key(state, 50, XKB_KEY_DOWN);   /* evdev 42: Shift_L */
	xkb_state_update_key(state, 24, XKB_KEY_DOWN);   /* evdev 16: q */
	{
		xkb_keysym_t sym = xkb_state_key_get_one_sym(state, 24);
		char name[80];

		if (xkb_keysym_get_name(sym, name, sizeof name) < 0) {
			strcpy(name, "(unnamed)");
		}
		printf("state: Shift_L+q -> %s\n", name);
		if (sym != XKB_KEY_Q) {
			printf("FAIL: Shift+q is not Q\n");
			failures++;
		}
	}
	xkb_state_update_key(state, 50, XKB_KEY_UP);
	{
		xkb_keysym_t sym = xkb_state_key_get_one_sym(state, 24);
		char name[80];

		if (xkb_keysym_get_name(sym, name, sizeof name) < 0) {
			strcpy(name, "(unnamed)");
		}
		printf("state: q -> %s\n", name);
		if (sym != XKB_KEY_q) {
			printf("FAIL: q without Shift is not q\n");
			failures++;
		}
	}

	xkb_state_unref(state);
	xkb_keymap_unref(keymap);
	xkb_context_unref(context);
	free(text);
	if (failures) {
		printf("xkb-probe: %d failure(s)\n", failures);
		return 1;
	}
	printf("xkb-probe: keymap ok\n");
	return 0;
}

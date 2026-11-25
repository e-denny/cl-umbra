# Vendored protocol XML

These are copies, not submodules: a build must not need the network, and a
version bump must show up as a diff.  Nothing here is compiled by the C tools at
build time except in tests, where `wayland-scanner` is used as an oracle
(`tests/unit/schema.lisp`).

## Pins

| Source | Version | How it was obtained |
|---|---|---|
| `wayland/wayland.xml` | wayland 1.26.0-1 (Arch) | copied from `/usr/share/wayland/wayland.xml` |
| `wayland-protocols/` | 1.50-1 (Arch) | copied from `/usr/share/wayland-protocols/{stable,unstable,staging}` |
| `wlr-protocols/` | commit `1106a4a1c57562ddd438c547da4c0d6dc150d624` | `git clone --depth 1 https://gitlab.freedesktop.org/wlroots/wlr-protocols`, then `.git` and build files removed |

Refresh procedure: copy the files in, update this table, run
`./scripts/run-tests.sh` (the oracle test re-derives every opcode and signature
from `wayland-scanner` and will fail loudly on a mismatch), and commit the XML
and the table together.

`wlr-protocols` is not packaged on Arch; it has to come from git.

## Licensing

Each XML file carries its own license in its `<copyright>` element: the core and
`wayland-protocols` files are MIT/HPND, `wlr-protocols` files are MIT. Those
notices are part of the files and must stay.  Our own code is
GPL-3.0-or-later (decision D13); vendored XML is not ours to relicense, and the
combination is GPL-compatible.

## Layout

```
protocols/
├── wayland/wayland.xml              wl_display, wl_registry, wl_compositor, …
├── wayland-protocols/
│   ├── stable/                      xdg-shell, linux-dmabuf, viewporter, …
│   ├── unstable/                    zwp_* interfaces
│   └── staging/                     ext-session-lock, cursor-shape, …
└── wlr-protocols/unstable/          layer-shell, screencopy, foreign-toplevel, …
```

69 XML files, 214 interfaces.

## How they are consumed

`cl-wayland-protocols` declares the files a build needs as `:wayland-protocol`
components; each is parsed at build time and compiled into a Lisp package named
after the protocol.  Nothing here is loaded by a running compositor.

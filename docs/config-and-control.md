# Configuration and control (`cl-umbra`)

Two subjects: how the compositor is **configured** (declarative, s-expression, reloadable —
D11) and how it is **controlled at runtime** (D14). The second is where Lisp changes the
architecture of a compositor, so it comes first: **`cl-umbra` has no IPC message layer.**

---

## 1. No message layer

Compositors grow message layers — `swaymsg`, `riverctl`, Umbriel's JSON socket, i3's IPC —
because their running state is not addressable from outside the process. A C or Rust
compositor cannot be asked "what is focused?"; it can only be sent a request that some
dispatch table knows how to answer. So the layer accumulates: a command registry, a wire
format, request/reply framing, an event stream, subscriptions, schema versioning, a client
library, and tests for all of it.

In Lisp the state *is* addressable, from any thread, at any time, by any process that can
open a socket:

```lisp
(umbra:focus :direction :down)
(umbra:workspace-windows "2")
(umbra:dispatch :spawn "kitty")
```

That is the message layer, and it is already in the language. Consequently `cl-umbra` does
**not** build:

| Not built | Because |
|---|---|
| command registry + argument schemas | functions have lambda lists, docstrings and `check-type` |
| JSON request/reply protocol | `read` and `print` are the protocol |
| event bus and subscriptions | `(push fn *hooks*)` is the subscription |
| schema versioning | the image has one version, and redefinition is how you upgrade |
| client library | `socat` is the client |
| IPC conformance tests | the tests are the ordinary function tests |

What is *kept* is a transport for processes that are not the image — a script, a bar, a
test harness — because those cannot call a function directly. That transport evaluates
forms; it does not define a second protocol on top of Lisp.

## 2. The three ways to talk to a running compositor

### 2.1 The image (canonical)

Attach SLY/SLIME to the compositor's SLYNK server and use it like any other Lisp process:
inspect the scene tree, redefine a layout function, look at a client's surface state, fix a
bug in a running session.

```lisp
(umbra:windows)                     ; list of window objects
(mapcar #'umbra:window-title *)     ; CLOS readers, not string keys
(describe (umbra:focused-window))
(umbra:reload-config)
```

Discipline (because a compositor is a real-time-ish server):

- Evaluations run **between dispatches**, not inside a protocol handler (D9).
- Long work uses `(umbra:defer (lambda () …))`, which runs it on a worker and returns
  immediately, rather than blocking the loop.
- The debugger is available to a human who asked for it, and the watchdog logs when a cycle
  is late. Sitting in a debugger prompt stops all clients — that is a property of the
  architecture, not a bug, and it is why the eval channel below never enters one.

### 2.2 The eval channel (scripts, tools, tests)

A Unix socket in `$XDG_RUNTIME_DIR` that reads s-expressions and returns the values of the
evaluations:

```sh
$ printf '(umbra:focus :direction :down)' | socat - UNIX-CONNECT:$UMBRA_SOCKET
NIL

$ printf '(mapcar (function umbra:workspace-name) (umbra:workspaces))' | socat - UNIX-CONNECT:$UMBRA_SOCKET
("1" "2" "3")

$ printf '(umbra:dispatch :spawn "kitty")' | socat - UNIX-CONNECT:$UMBRA_SOCKET
;;; error: no such command: :spwan
```

- **Wire format:** forms in, printed values out, one line per form; errors are printed as
  `;;; error: <condition>` comments so a shell script sees them without a parser. Multi-line
  forms work because the reader, not a line splitter, delimits them.
- **Execution:** at the next safe point in the main loop, from the queue, with a wall-clock
  deadline (default 5 s) that aborts runaway forms. `enqueue` from `umbra` is how a script
  asks for work that should not block the loop.
- **No debugger, no thread control, no interruption of live handlers.** Errors are values.
- **Auth:** socket mode 0600, owned by the compositor's uid, `SO_PEERCRED` matched, optional
  token file for hosts where `$XDG_RUNTIME_DIR` is shared. Same-uid only.
- **Logging:** every evaluation logs the peer pid and the form at `:debug`; anything that
  changes configuration logs at `:info`.

Since the transport is just Lisp text, there is no client library to write or version:
`socat`, `nc`, `emacsclient --eval`, or a five-line Lisp script all work. A small
`umbra-cmd` wrapper exists for convenience (`umbra-cmd '(umbra:focus :down)'`), and is
nothing more than a socket and a `prin1`.

### 2.3 Wayland clients (bars, launchers, lockers)

Panels, notification daemons, launchers and lock screens stay **separate Wayland clients**,
not in-image code, so a crash in a bar does not take the session with it. They talk to the
compositor through protocols, not IPC: `wlr-layer-shell`, `wlr-foreign-toplevel` (window
list and activation), `xdg-activation`, `ext-session-lock`, `wlr-screencopy`.

A bar written in Lisp may use the eval channel to ask for workspace state, or simply keep its
own connection and subscribe by evaluating one form:

```lisp
;; sent once over the eval channel; the closure lives in the compositor and writes
;; events to the caller's stream
(umbra:subscribe
 (lambda (event)
   (print-event-to-my-socket event)))
```

That is the entire "event bus": a closure and a stream. It has no schema, no version, no
subscription registry, and no backpressure logic beyond what the stream itself does.

### 2.4 Compatibility, only where someone actually needs it

If a third-party bar requires a foreign protocol (`swaymsg`'s IPC, say), the answer is a
small compatibility *adapter* maintained outside the compositor's core — phase 7, only on
request, only as far as a real tool needs. It is not the architecture.

## 3. Stability surface

Functions are the API, so the API is discoverable and documented in the ordinary way:

- Package `umbra` exports the stable command and query functions, each with a docstring and
  a real lambda list: `focus`, `move`, `resize`, `close`, `workspace`, `move-to-workspace`,
  `workspaces`, `windows`, `outputs`, `spawn`, `reload-config`, `screenshot`, `subscribe`,
  `defer`.
- `(documentation 'umbra:focus 'function)` and `(apropos "WORKSPACE")` answer "what can I
  call?" without reading a protocol document.
- Internal modules (`umbra.layout`, `umbra.scene`, …) are not exported; scripts that reach
  into them are on their own, which is a much smaller promise than a versioned IPC schema and
  costs nothing to make.
- Deprecation is a warning from a function, not a protocol version bump.

## 4. Safety, honestly

Evaluating a form in the compositor is exactly as powerful as running a shell as that user.
That is the trade: no schema, no sandbox, full power.

- The channel is **opt-in** (`(control :eval-socket t)` in the config) and off in the
  default config for a new user.
- Mode 0600 + peer-credential check means sandboxed applications (Flatpak, etc.), which get
  a private `$XDG_RUNTIME_DIR`, cannot reach it.
- A read-only mode binds a flag that mutating commands check; it is advisory (documented as
  such) and exists to protect against accidents, not attackers.
- The deadline protects the loop from `(loop)`; it cannot make an interrupted mutation safe,
  so commands are expected to be short, and long work is `defer`red.
- The watchdog (§2.1) names the offending form when a cycle runs long.

## 5. Configuration (D11)

### 5.1 Reading it safely

```lisp
(defun read-config (path)
  "Read PATH as data. Returns (values forms source-lines) or signals CONFIG-ERROR."
  (let ((source (read-file-string path :limit (* 512 1024))))
    (with-input-from-string (in source)
      (let ((*read-eval* nil)                 ; no #. reader evaluation
            (*package* (find-package :umbra.config))
            (*readtable* *config-readtable*)
            (forms '()) (lines '()))
        (loop for start = (file-position in)
              for form = (read in nil :eof)
              until (eq form :eof)
              do (push form forms)
                 (push (line-number source start) lines))
        (values (nreverse forms) (nreverse lines))))))
```

- `*read-eval*` is `nil`, the readtable has no dispatch macros, and the file is size-capped.
- Line numbers come from a newline index, so diagnostics point at a line.
- Unknown sections and unknown keys are errors with a suggestion ("did you mean `:gaps`?"),
  not silently ignored.
- Referential integrity is checked before applying: command names exist, workspaces exist,
  outputs are connected or marked `:hotplug`.
- `(enable-lisp-config)` switches to full evaluation for users who want loops and helpers.
  It is an explicit, documented opt-in: pasting a stranger's config should not execute code.

### 5.2 Shape

```lisp
;; ~/.config/umbra/init.lisp
(output "DP-1" :mode '(2560 1440) :refresh 165 :scale 1.0
                :transform :normal :position '(0 0)
                :workspaces ("1" "2" "3" "4"))
(output "HDMI-A-1" :scale 1.5 :position '(2560 0) :workspaces ("5" "6"))

(layout :default :master :master-count 1 :master-ratio 0.6 :gaps 8)
(workspace-layout "3" :scrolling)

(bind "Super+Return"  :spawn "kitty")
(bind "Super+j"       (focus :direction :down))
(bind "Super+Shift+1" (move-to-workspace "1"))
(bind "XF86AudioRaiseVolume" :spawn "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+")

(device "keyboard" "*" :layout "us" :variant "colemak" :repeat '(25 600))
(device "pointer"  "*" :accel 0.3 :natural-scroll t)

(rule :app-id "firefox" :workspace "2" :layout :master)
(layer-rule :namespace "waybar" :output "*" :exclusive-zone 34)

(startup "waybar")
(env "MOZ_ENABLE_WAYLAND" "1")
(control :eval-socket t :deadline 5)
```

Sections are declarative; nothing in the default dialect has side effects at read time.
`:spawn` is a command string for `/bin/sh -c`, never Lisp. Binding actions are calls to the
same exported functions the eval channel uses, so a binding, a script and a REPL call are
the same code path.

### 5.3 Applying and reloading

```
read → validate → resolve references → build desired state
     → diff against current → apply (transaction) → publish
```

- **Atomic:** output changes go through the same commit path as hotplug (`framework.md` §3);
  failure restores the previous state. A bad reload cannot leave the session outputless.
- **Diffed:** unchanged sections are not reapplied, so changing one binding does not
  re-create outputs or re-flow windows.
- **Rules apply to new windows** unless `(rule … :reapply t)` says otherwise.
- **Triggers:** `SIGHUP`, `(umbra:reload-config)`, or an inotify fd in the reactor
  (fallback: mtime poll).
- **Failure:** the running config stays in force, errors are logged with file and line, and
  the same list is returned by the call.

### 5.4 Diagnostics

- `umbra --check-config [path]` validates without starting, exit 1 on error.
- Errors carry `:file`, `:line`, `:form`, `:expected`, `:got`, `:hint`.
- Warnings (deprecated key, unconnected output, unknown device) do not abort.
- `(umbra:current-config)` and `(umbra:config-schema)` are REPL-inspectable: the running
  image is the source of truth.

## 6. Testing

- Reader: `#.` inert; oversized file rejected; unknown keys reported with line numbers; depth
  cap enforced.
- Schema: valid/invalid fixture per section; every error names the offending key.
- Reload: a broken config changes nothing (assert outputs, binds, workspace assignment);
  a good one changes exactly what it says.
- Atomic output config: an impossible mode must not blank the display.
- Eval channel: forms round-trip; errors are values, never debugger entries; deadline aborts
  `(loop)`; peer check rejects another uid; socket mode is 0600; a slow reader cannot grow
  the compositor.
- Functions: ordinary unit tests, which is the point — the control surface has no separate
  conformance suite to maintain.

## 7. Non-goals

- A message layer, command registry, JSON schema, event bus or subscription protocol (D14).
- A TOML reader (D11).
- Remote control. The socket is local, `0600`, peer-checked; there is no TCP listener,
  because a compositor is not a network service.
- A sandbox around the eval channel. It is a shell; treat it like one.

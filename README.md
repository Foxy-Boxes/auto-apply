[![build](https://github.com/Foxy-Boxes/auto-apply/actions/workflows/build.yml/badge.svg)](https://github.com/Foxy-Boxes/auto-apply/actions/workflows/build.yml)

# Auto-Apply — a job-application assistant you can hand to anyone

**Auto-Apply** turns the macOS automation library below into a personal job tool: it
keeps your application info in a vault (passwords in the macOS Keychain), finds
internships/jobs on real company career sites, logs you in to each portal once, and
fills applications for you — **never submitting**; you review and click Submit.

It's built to be **owned by a non-programmer**. They install it once, then change it by
*talking to an assistant* (OpenAI's **Codex CLI**) in plain English — "also search
Microsoft", "add my work authorization". No scripting required.

### Get started
- **To use/own it:** read [`cvfill/setup/HANDOVER.md`](cvfill/setup/HANDOVER.md), then
  double-click `cvfill/setup/install.command`. It installs & signs in Codex, builds the
  tools, creates your info vault, and makes a clickable **Auto-Apply** app that opens a
  primed assistant session.
- **How the assistant is primed:** [`cvfill/AGENTS.md`](cvfill/AGENTS.md) (its guide) +
  `cvfill/setup/onboarding_prompt.md` (first-run setup).

### The tools (in `cvfill/`)
| File | Does |
|------|------|
| `vault.py` | Store your info once; secrets go to the macOS Keychain. |
| `jobsearch.py` | Find internships/jobs (NVIDIA/Apple/Google + Greenhouse/Lever) — deterministic, no guessing. |
| `webauth.py` | Queue + hold a login per career portal (log in by hand once). |
| `webfill.py` | Fill a web application from the vault, verify each field, stop before Submit. |
| `fill.py` | Same idea for native macOS app forms (focus-free, via Accessibility). |

> Your personal data (vault, resume) is **never** committed — it lives only on your Mac
> (`~/.cvfill/` and the Keychain). This repo ships blank templates only.

---

# appshim — scripting macOS AppKit apps via `DYLD_INSERT_LIBRARIES`

A C shim you preload into a Cocoa application. Once loaded it hooks AppKit's
event and action dispatch, opens a Unix domain socket, and lets you drive the
app's real UI — enumerate windows and views, synthesize clicks and keystrokes,
fire control actions, walk menus, take screenshots, and stream every event the
app receives — by sending one-line text commands and reading back JSON.

It is a test / automation harness. It injects only into a process **you** launch
with the shim in `DYLD_INSERT_LIBRARIES`, and the control socket is a
`0600` Unix socket owned by your user.

## What it is (and how it differs from clicking the screen)

Synthesized input goes in through `-[NSApplication postEvent:atStart:]`, so it
travels the app's own event path: hit-testing, button tracking, target/action.
The app cannot tell a scripted click from a real one — the test app's log shows
`sender=NSButton` for a synthesized press. This is in-process UI scripting, not
screen-coordinate robotics, so it needs no Accessibility permission and no
global event tap.

## Build

```
make all
```

Produces three things in `build/`:

| file            | what it is                                               |
|-----------------|----------------------------------------------------------|
| `appshim.dylib` | the injected library                                     |
| `appctl`        | command-line client for the socket                       |
| `testapp`       | a small AppKit app (buttons, text field, menu) to try it |

## Run the demo

```
make run-test
```

That launches `testapp` with the shim preloaded and the socket at
`/tmp/appshim-test.sock`. In another terminal:

```
./build/appctl -s /tmp/appshim-test.sock ping
./build/appctl -s /tmp/appshim-test.sock windows
./build/appctl -s /tmp/appshim-test.sock tree key
```

Find a control and click it:

```
ID=$(./build/appctl -s /tmp/appshim-test.sock find Increment \
     | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
./build/appctl -s /tmp/appshim-test.sock click "$ID"
```

Type into the field, then fire its Submit button's action directly:

```
F=$(./build/appctl -s /tmp/appshim-test.sock find name | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)
./build/appctl -s /tmp/appshim-test.sock settext "$F" "hello shim"
S=$(./build/appctl -s /tmp/appshim-test.sock find Submit | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)
./build/appctl -s /tmp/appshim-test.sock action "$S"
```

Watch every event the app receives (stream until Ctrl-C):

```
./build/appctl -s /tmp/appshim-test.sock watch
```

## Injecting into another app

```
DYLD_INSERT_LIBRARIES=/absolute/path/build/appshim.dylib \
APPSHIM_SOCK=/tmp/myapp.sock \
/path/to/YourApp.app/Contents/MacOS/YourApp
```

If `APPSHIM_SOCK` is unset the socket is `/tmp/appshim-<pid>.sock`. `appctl`
auto-detects a single `/tmp/appshim-*.sock`, so you can often drop `-s`.

**`DYLD_INSERT_LIBRARIES` is ignored for processes with the hardened runtime or
library-validation** (most notarized App Store / signed apps). It works on apps
you build yourself, unsigned apps, and apps signed with the
`com.apple.security.cs.allow-dyld-environment-variables` and
`disable-library-validation` entitlements (or ad-hoc re-signed with them). This
is the intended OS security boundary; the shim does not try to defeat it.

## Protocol

Connect to the socket, send one command per line, read one JSON object per line
back. A client that sends `watch` additionally receives an asynchronous JSON
line per observed event until it sends `unwatch` or disconnects. Strings with
spaces are `"double quoted"`.

### Commands

| command | effect |
|---|---|
| `ping` | process info, whether hooks installed, watcher count, lock state |
| `windows` | list all windows (number, title, frame, key/main/visible) |
| `tree [win] [all]` | view hierarchy of a window (`all` = include frame view) |
| `find <text>` | views whose class/title/id/value/label match (case-insensitive) |
| `get <viewid>` | one view's current properties |
| `at <win> <x> <y>` | hit-test a point, report the view under it |
| `click <viewid> [count] [mods]` | synthesize a left click at the view's center |
| `rclick <viewid>` | synthesize a right click |
| `mouse <win> <x> <y> [left\|right\|middle] [count] [mods]` | click at raw window coords |
| `press <viewid>` | `-performClick:` (direct, no event) |
| `action <viewid>` | send the control's own target/action |
| `perform <viewid> <selector>` | send an arbitrary no-arg selector to the view |
| `focus <viewid>` | make the window key and the view first responder |
| `settext <viewid> <text>` | set a field's `stringValue` / text view's `string` |
| `type <text>` | synthesize keystrokes to the key window |
| `key <keycode> [mods\|-] [chars]` | synthesize one key down/up |
| `menus` | dump the main menu tree |
| `menu <A>B>C>` | perform a menu item by path, e.g. `menu "File>Save"` |
| `screenshot <win> <path.png>` | render a window's content view to PNG |
| `activate` | bring the app to the front |
| `watch` / `unwatch` | start / stop the event stream on this connection |
| `lock on\|off` | drop real user input (synthesized input still flows) |
| `suppress <sel>` / `unsuppress <sel>` / `suppressed` | block / allow a target/action selector |
| `help` | list commands |

`<viewid>` is the `"id"` (a `0x…` pointer) from `tree`/`find`/`at`. It is
validated against the live hierarchy on every call, so a stale id returns an
error rather than dereferencing freed memory. `[mods]` is any of
`shift ctrl alt cmd fn` joined however you like, e.g. `cmd+shift`.

### Event stream shapes

Input event:

```json
{"event":"input","type":1,"name":"leftMouseDown","window":7044,
 "x":80,"y":176,"mods":0,"synthetic":true,"clickCount":1,"button":0,
 "view":"0x…","viewClass":"NSButton","viewTitle":"Increment","viewId":"inc"}
```

Action dispatch:

```json
{"event":"action","selector":"bump:","target":"0x…","targetClass":"Ctl",
 "sender":"0x…","senderClass":"NSButton","senderTitle":"Increment",
 "senderId":"inc","suppressed":false}
```

## How it works

- **Hooks.** On load the constructor swaps the implementations of
  `-[NSApplication sendEvent:]` and `-[NSApplication sendAction:to:from:]` with
  `method_setImplementation`, keeping the originals to call through. `sendEvent:`
  sees every input event; `sendAction:to:from:` sees every control/menu action.
- **Thread safety.** The socket server runs on its own pthread. Every command
  that touches AppKit is marshalled onto the main thread with `dispatch_sync_f`,
  so UI state is only ever read or mutated on the main run loop.
- **Synthetic input.** Built with `+[NSEvent mouseEventWithType:…]` /
  `keyEventWithType:…` and posted via `postEvent:atStart:`. Posted events are
  tagged (by object identity, and mouse events also by a sentinel
  `eventNumber`) so the hook can label them `synthetic` and the input lock can
  let them through while dropping real input.
- **No AppKit headers.** Everything is plain C through `objc_msgSend` and the
  runtime API, so it compiles as C and stays small.

## Limitations

- Subject to `DYLD_INSERT_LIBRARIES` restrictions (see above).
- `type`/`key` deliver `keyDown`/`keyUp` with keycode 0; text controls that read
  `-characters` accept them, but code that switches on hardware keycodes won't.
  Use `settext` for reliable field population.
- The input lock's synthetic-vs-real detection is best-effort; prefer using
  `lock` and synthesis in separate phases rather than simultaneously.
- Screenshot captures the content view's rendering, not window chrome or
  overlapping windows.

## Beyond native AppKit: hardened apps and non-AppKit UIs

The injecting shim works on native AppKit apps you can launch without the
hardened runtime. Two things break that, and each has a different answer.

### Wall 1 — the app is signed with the hardened runtime

`DYLD_INSERT_LIBRARIES` is stripped from hardened-runtime processes that lack
the `com.apple.security.cs.allow-dyld-environment-variables` entitlement
(Firefox, Chrome, most notarized apps). This is enforced by the kernel (AMFI);
you cannot talk dyld out of it from the environment.

`sandbox/shim-launch.sh` works around it for apps that do **not** verify their
own signature at runtime: it copies the bundle, re-signs the whole thing ad-hoc
(bottom-up, nested code first) with permissive entitlements
(`allow-dyld-environment-variables`, `disable-library-validation`), and launches
the copy with the shim inserted.

```
make all
./sandbox/shim-launch.sh /Applications/SomeApp.app
./build/appctl -s /tmp/appshim-SomeApp.sock ping
```

Verified: this loads the shim into a re-signed copy of Firefox. What it does
**not** do, and cannot:

- defeat **SIP**-protected system apps (re-signing them is blocked),
- help apps that **self-check** their signature (they refuse or crash),
- grant `task_for_pid` on a hardened app already running (injecting into a live
  process needs its task port, which the kernel denies).

"Bypass it for *any* program" in the absolute sense means disabling SIP and AMFI
system-wide from recovery — a global security downgrade, not a sandbox. This
project does not go there.

### Wall 2 — the app's UI is not AppKit

Even with the shim loaded, Firefox/Chrome/Electron/Qt paint their own widgets
into one compositor `NSView`. The shim's `tree`/`find` see the window and an
opaque view, not buttons. Worse, those hosts run their own main-thread loop that
may not drain libdispatch's main queue, so the shim now **probes once and
fast-fails** a command rather than deadlocking:

```
{"ok":false,"error":"host main thread is not servicing the dispatch queue ..."}
```

For those apps, interception belongs at a different layer.

### `axctl` — out-of-process scripting for (almost) any app

`build/axctl` drives apps through the macOS **Accessibility API**: no injection,
no re-signing, works across process boundaries. It reads the target's
accessibility tree, finds an element by text, reports its screen rectangle, and
clicks it — either by asking the element to press itself (`press`, clean) or by
posting a real `CGEvent` click at its center (`click`).

```
./build/axctl trust                 # check/raise the Accessibility permission
./build/axctl apps                  # running GUI apps with pids
./build/axctl tree  Firefox 6       # accessibility tree
./build/axctl find  Firefox "Reload"
./build/axctl press Firefox "Reload"
./build/axctl click Firefox "New tab"
./build/axctl clickxy 640 220       # click absolute screen coords
```

Requirements and limits:

- The controlling process (your terminal, or Claude) must be granted
  **Accessibility** in System Settings > Privacy & Security.
- The target must have a **window open** and expose an a11y tree. A windowless
  background app shows only its menu bar.
- Gecko/Chromium/Electron keep their full a11y tree **off** until an assistive
  client asks; `axctl` sets `AXManualAccessibility`/`AXEnhancedUserInterface` on
  the app element to request it.

### Which tool for which app

| target | tool |
|---|---|
| native AppKit app, you launch it, not hardened | **appshim** (inject) |
| native AppKit app, hardened, no self-check | **shim-launch.sh** then appshim |
| any app with a window and an a11y tree | **axctl** (Accessibility) |
| browser page content specifically | the browser's own WebDriver / CDP |
| SIP-protected or self-verifying app | not supported without disabling SIP/AMFI |

### Headless mode — running an AppKit app against a virtualized GUI

`APPSHIM_HEADLESS=1` makes the shim interpose AppKit's window ordering so every
window is relocated far offscreen as it appears (and `constrainFrameRect:toScreen:`
is neutralized so AppKit does not clamp it back). The app runs completely
normally -- event routing, key status, drawing, target/action -- but nothing
reaches a physical display, and the process runs as an accessory (no Dock icon).
You drive and screenshot it entirely through the socket.

```
APPSHIM_HEADLESS=1 APPSHIM_SOCK=/tmp/s.sock \
  DYLD_INSERT_LIBRARIES=$PWD/build/appshim.dylib ./build/testapp &
./build/appctl -s /tmp/s.sock windows        # window frame origin is ~200000,200000
./build/appctl -s /tmp/s.sock click <viewid> # still drives the real control
./build/appctl -s /tmp/s.sock screenshot key /tmp/out.png   # offscreen render
```

This is "virtualize the GUI" done by interposition rather than reimplementation:
the real AppKit still runs, we only redirect where its windows live. It is the
tractable middle ground between a full framework reimplementation (GNUstep/
Darling, impractical) and a whole-OS VM (Virtualization.framework). Its reach is
the same as the shim's: native-AppKit apps, after the re-sign for hardened ones.
It does nothing for Gecko/Chromium, which draw their own widgets and never call
these AppKit methods.

## uidrive — unified external driver (no injection), with virtual-display fallback

`build/uidrive` is one tool over two backends, chosen with automatic fallback.
It needs no injection and no re-signing; it drives apps from outside.

- **Standard backend:** locate elements via the Accessibility API, click them with
  real `CGEvent`s (or `AXPress`), type with `CGEvent`, and capture the app's
  on-screen window with ScreenCaptureKit. Works on any app with an a11y tree.
- **Virtual-display backend:** create a software display with the private
  `CGVirtualDisplay` API (the local analog of a VM's virtual GPU), move the
  target window onto it so it leaves the real screens, drive it there, then tear
  the display down and restore the window. Verified working on macOS 27.

If the virtual display is unavailable (private API missing or failing), every
command falls back to the standard backend on the real screen.

```
uidrive trust                         # check / raise the Accessibility permission
uidrive info <pid|app>                # what each backend can do for this app
uidrive do  <pid|app> find <text>     # list matching elements + screen rects
uidrive do  <pid|app> press <text>    # AXPress the first match
uidrive do  <pid|app> click <text>    # CGEvent click at its center (AXPress fallback)
uidrive do  <pid|app> type "<text>"   # synthesize keystrokes to the focused element
uidrive do  <pid|app> key <name> [mods]
uidrive do  <pid|app> capture out.png # ScreenCaptureKit window grab
uidrive session <pid|app> [--isolate] # REPL; --isolate moves the window to a virtual display
```

In a session: `tree find press click type key capture isolate on|off info quit`.
The virtual display lives only as long as the session process, so isolation runs
inside `session`; quitting (or `isolate off`) restores the window.

### Permissions and limits

- **Accessibility** permission is required for the controlling process (your
  terminal) to read trees and post events. `uidrive trust` raises the prompt.
- **Screen Recording** permission is required for `capture` (ScreenCaptureKit).
  Without it, capture reports that and the rest still works.
- The virtual-display API is **private** and version-fragile. uidrive probes it
  and falls back; a session that crashes mid-isolate can strand the window on the
  torn-down display, so prefer a clean `quit`.
- Do **not** set `AXEnhancedUserInterface` on native AppKit apps; it disturbs
  their window a11y tree. uidrive sets only `AXManualAccessibility` (the
  Chromium/Gecko opt-in).

### Which backend, which tool

| need | use |
|---|---|
| drive a native-AppKit app you launch | `appshim` (in-process, richest) |
| drive any app from outside, no injection | `uidrive do` (standard backend) |
| run an app's GUI off your real screens | `uidrive session --isolate` (vdisplay, falls back) |
| a hardened AppKit app, in-process | `shim-launch.sh` then `appshim` |

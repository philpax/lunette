# lunette v1 Implementation Plan — Phase 4: Monitor mirroring and host input

**Goal:** The host desktop visible and controllable from inside lunette.

**Architecture:** `lunette-capture` wraps wlx-capture, which drives xdg-desktop-portal ScreenCast and PipeWire. Frames arrive on PipeWire's own thread and are forwarded raw to the main thread, where the Phase 2 dmabuf import path turns them into textures — one import path, no second GPU queue. Monitor identity follows niri's model: a matcher over connector, make, and model, keyed on the descriptor with a connector fallback. Input injection goes through a `HidProvider` trait with a real ordered fallback chain.

**Tech Stack:** wlx-capture 0.6.0 (git-pinned from the WayVR monorepo), PipeWire 0.10, xdg-desktop-portal ScreenCast v5+, uinput, `zwlr_virtual_pointer_v1`, `zwp_virtual_keyboard_v1`.

**Scope:** Phase 4 of 8. The design specifies this phase at intent level, so the task detail below is derived from investigation rather than from the design plan.

**Codebase verified:** 2026-08-06.

---

## Acceptance criteria coverage

### lunette-v1.AC3: The host desktop is visible and controllable
- **lunette-v1.AC3.1 Success:** A mirrored monitor appears as a source with a texture matching the captured output's resolution.
- **lunette-v1.AC3.2 Success:** Pointer coordinates sent to a monitor sink move the host cursor to the corresponding position on that physical display.
- **lunette-v1.AC3.3 Success:** Keystrokes sent to a monitor sink reach whatever the host compositor currently focuses.
- **lunette-v1.AC3.4 Success:** Monitors identify themselves by connector name via the portal's `mapping_id`, without the user selecting screens in a prescribed order, and that identity survives a restart.
- **lunette-v1.AC3.5 Success:** Dismissing a mirrored monitor stops its capture stream; re-adding it restarts capture.

**AC3.4 is restated by Task 3.** Its stated mechanism does not work portably. The outcome it asks for — no prescribed selection order, identity surviving a restart — is achievable and is what this phase delivers. See the investigation notes and Task 3.

---

## Facts established by investigation

### `mapping_id` cannot carry monitor identity

`mapping_id` was added in ScreenCast portal **version 5**, and its documented purpose is to match a libei region in a RemoteDesktop session, not to name an output. Its content is backend-defined and inconsistent:

- **xdg-desktop-portal-wlr** sets it to the `wl_output` name, which on wlroots is the DRM connector name: `sd_bus_message_append(reply, "{sv}", "mapping_id", "s", cast->target->output->name)` (`src/screencast/screencast.c:666-668`).
- **mutter / GNOME** sets it to `g_uuid_string_random()` — an opaque random UUID from a per-EIS table (`src/backends/meta-eis.c:526-538`) — and emits it **only when the ScreenCast session is attached to a RemoteDesktop session** (`src/backends/meta-screen-cast-stream.c:426-440`, guarded by `if (remote_desktop_session)`). A plain ScreenCast session on GNOME gets none.
- **xdg-desktop-portal-kde** never emits it.

So AC3.4's mechanism yields a connector name on wlroots only, an unstable random string on GNOME under one specific session shape, and nothing on KDE.

WayVR does not use it either — `grep -rn mapping_id` over the whole checkout returns nothing. `parse_streams` (`wlx-capture/src/pipewire/mod.rs:693-733`) reads only `node_id`, `position`, and `size`. Its Wayland path requests one stream per output with `allow_multiple: false` (`overlays/screen/pw.rs:93-99`) and prompts the user per screen, one at a time — exactly the prescribed-order ritual AC3.4 exists to eliminate. Its X11 path uses `allow_multiple: true` and matches streams to monitors heuristically by geometry (`overlays/screen/x11.rs`, `best_match`).

The portable mechanism is that geometry match: correlate each stream's `position` and `size` against `wl_output`/`xdg_output` logical geometry. It works on every backend, and it is what wlx-overlay-s itself does.

### niri's identity model, and the ceiling on it

niri solves the adjacent problem well and is worth copying closely.

`OutputName` (`niri-config/src/output.rs:307`):

```rust
pub struct OutputName {
    pub connector: String,
    pub make: Option<String>,
    pub model: Option<String>,
    pub serial: Option<String>,
}
```

Five ideas to take:

1. **It is a matcher, not an equality type.** `OutputName::matches(&self, target: &str)` (`output.rs:195-256`) tries the connector case-insensitively first, then the `"{make} {model} {serial}"` descriptor with `"Unknown"` substituted for absent fields. niri deliberately does not derive `Eq`, and its ordering helper is a plain method named `compare` with a comment saying "you should use `Self::match`, not Eq", precisely so nobody compares identities structurally.
2. **Saved state keys on the descriptor, with a connector fallback.** `OutputId::new` uses `format_make_model_serial_or_connector()` (`output.rs:177-184`), so the key survives the monitor moving to a different port, and degrades gracefully when no descriptor exists.
3. **Duplicate descriptors are a first-class case.** `src/backend/tty.rs:1050-1080` searches for duplicates at hotplug and strips the *newer* connector's descriptor, demoting it to connector-only, with a warning. Its comment: "Make/model/serial can match exactly between different physical monitors… our Layout does not support such duplicates and will panic."
4. **Sort by descriptor before assigning positions.** `Niri::reposition_outputs` (`src/niri.rs:2700-2760`) does this because udev connector order is arbitrary, so sorting by descriptor makes the arrangement independent of plug order.
5. **Refresh the stored key on reattach.** `workspace.rs:517` re-normalises `original_output` when a workspace lands on a matching output, so a key stored in a degraded form upgrades once better information exists.

**The ceiling: lunette cannot reach niri's identity strength.** niri reads the DRM connector's EDID blob directly, parsed with the `libdisplay-info` crate (`Cargo.toml:76`, extraction at `src/backend/tty.rs:3239`, `get_edid_info`), because it *is* the compositor. lunette is a client of the host compositor. **Serial is not available over the `wl_output` protocol** — the `geometry` event carries make and model only.

So lunette's identity is at best `(make, model)` plus logical geometry, plus a connector name from `mapping_id` where a backend supplies a real one. Two identical monitors of the same model are therefore indistinguishable by descriptor, which makes niri's demote-to-connector rule **more** important here than it is in niri, not less.

Incidental: niri pins smithay at a git rev (`Cargo.toml:28-38`, rev `ff5fa7df392cecfba049ffed55cdaa4e98a8e7ef`, resolving to 0.7.0), not crates.io 0.7.0. lunette pins crates.io. They are not the same code, and a behaviour observed in niri may not hold for us.

### wlx-capture: the published version is the wrong one

Two versions exist and the difference is decisive.

**v0.5.4** — the GitHub repo and its last tag. Depends on `ashpd` 0.11 with `default_features = false, features = ["async-std"]`, and on a **fork** of pipewire-rs (`gitlab.freedesktop.org/galister/pipewire-rs`, rev `ba32202c`). Both are real problems: async-std is a second executor in a codebase whose rules say tokio, and a git pin on a personal fork is a maintenance liability.

**v0.6.0** — vendored in the WayVR monorepo at `inspiration/wayvr/wlx-capture`, edition 2024. It **drops `ashpd` entirely**, replacing it with `dbus` 0.9.12 (`features = ["futures"]`) driving a hand-rolled portal client in `src/pipewire/dbus_screencast.rs` (105 lines), and **drops the fork** for crates.io `pipewire` 0.10, which landed 17 May 2026. There is **no async runtime in its dependency tree at all** — no async-std, no smol, no zbus.

Both concerns are therefore already resolved upstream, in the copy already present in `inspiration/`. The remaining issue is provenance: the standalone repo is stuck at 0.5.4 while live development happens inside the WayVR monorepo with no independent tag. lunette pins the WayVR repository at a revision and depends on its `wlx-capture` path.

That sits awkwardly with `CONTRIBUTING.md:48` — "wlx-capture is a git-pinned external dependency, not a vendor. Fixes to it go upstream" — which assumes a standalone upstream. The rule still holds; the sentence needs a clause. Task 1 amends it.

**Weight.** Against a baseline that already carries smithay 0.7, ash, and mlua, wlx-capture 0.6.0 with all features adds **53 crates**: roughly 33 for PipeWire (of which about 25 are `pipewire-sys`'s build-time bindgen chain), 9 for `dbus` and its futures dependencies, one for `rxscreen`, and the rest small. Feature pruning buys almost nothing — `pipewire` implies `wayland`, and dropping `xshm` removes exactly one crate. Hand-rolling the equivalent, a zbus portal client plus upstream pipewire-rs plus our own screencopy code, comes to roughly **58–63 crates** — more, not fewer — plus about 2,300 lines of capture code. Licence is GPL-3.0, matching lunette's.

### Capture threading

`PipewireCapture` spawns its own thread running a PipeWire `MainLoop`, and the receive callback is a bare `fn` pointer — not a closure — executed on that thread (`wlx-capture/src/lib.rs:24`). WayVR does its Vulkan import inside that callback (`overlays/screen/capture.rs`, `receive_callback`), which requires a second GPU queue, and falls back to wrapping the capture in `MainThreadWlxCapture` when none exists.

lunette does not do that. Raw frames go up a channel and every Vulkan import happens on the main thread, reusing the Phase 2 path. One import path, no second queue, and no assumption about LÖVR's queue topology, which no patch currently exposes. The cost is a channel hop per frame.

Several types here are not `Send` and must stay on the capture thread: `ScreenCastManager` polls D-Bus futures with a no-op waker on the calling thread (`pipewire/mod.rs:840`), `DbusFuture<T> = Pin<Box<dyn Future<…>>>` is not `Send` (`mod.rs:632`), and `ScreenCastParams.token` is an `Rc<str>` in a public API type (`mod.rs:46`).

`WlxCapture::receive()` is a non-blocking `try_iter().last()` — it deliberately drops stale frames. That is the behaviour we want and should not be changed.

### Restore tokens are single-use

`persist_mode` takes `0` (do not persist), `1` (while the application runs), and `2` (until explicitly revoked). The backend may **downgrade** the granted mode, and returns the granted value in the `Start` response.

The token is explicitly single-use: once used it is invalidated, and `Start` returns a **new** token. A client that stores only the first token loses restore on the second run. WayVR gets this right, rewriting `<config>/conf.d/pw_tokens.yaml` on every change after a successful `Start` (`overlays/screen/pw.rs:280-294`, `state.rs:352-370`), keyed by output name.

Restore is best-effort and does not guarantee the prompt is skipped. xdg-desktop-portal-wlr's restore payload is vendor-tagged and versioned, skips data from another vendor (`screencast.c:415`), rejects unknown versions (`:462`), and its v1 payload carries only `output_name` (`:706-711`) — so an unplugged or renamed monitor silently falls back to a prompt with no error. There is a known upstream issue that persist mode does not reliably preserve monitor selection.

### Input injection

`HidProvider: Sync + Send` (`wayvr/src/subsystem/hid/provider/mod.rs:8`) has ten methods: `mouse_move`, `mouse_move_rel`, `send_button`, `wheel`, `set_desktop_extent`, `set_desktop_origin`, `set_modifiers`, `send_key`, `set_keymap`, `commit`. Pointer and button calls only accumulate; `commit` is called once per frame.

**There is no ordered fallback.** `HidWrapper::new` (`subsystem/input.rs:22-41`) matches a config enum and calls exactly one initialiser; on failure it installs `DummyProvider` and shows a toast. It does not try `wl_virtual` after uinput fails. `docs/host-desktop.md:37` — "uinput is tried first because it works regardless of the host compositor" — describes behaviour that does not exist.

**uinput.** Two `/dev/uinput` handles, one keyboard and one mouse. The mouse declares `EV_ABS` on `ABS_X`/`ABS_Y` with `min=0, max=32768, resolution=10` (`MOUSE_EXTENT = 32768.0`, `hid/mod.rs:40`), `EV_REL` for hi-res wheels, and `EV_KEY` for three buttons. The mapping is global, not per-monitor (`uinput.rs:124`):

```rust
let pos = (pos - self.desktop_origin) * (MOUSE_EXTENT / self.desktop_extent);
```

Per-monitor targeting happens upstream: each screen holds `logical_pos`/`logical_size` and builds an `Affine2` from them, including rotation and flip (`overlays/screen/backend.rs:93-145`), then maps hit UV to global desktop coordinates (`backend.rs:310`, `:343`). The device's fixed normalised range is why hotplug needs no device recreation — only the extent and origin change.

`set_keymap` is a **no-op** on uinput (`uinput.rs:219`). Layout handling works only because uinput injects raw keycodes that the host interprets under its own layout. Only `wl_virtual` uploads a keymap.

**`wl_virtual`.** `zwlr_virtual_pointer_v1` and `zwp_virtual_keyboard_v1`, requiring a `wl_seat` v4..=9 (`wl_virtual.rs:215-229`). Its coordinate handling is better — `motion_absolute(time, x, y, x_extent, y_extent)` takes the extent per call (`wl_virtual.rs:50-56`), so no fixed constant and nothing to recreate on layout change. But it is implemented by the wlroots family only: sway, Hyprland, wayfire, labwc, dwl, river, niri. **KWin and mutter do not implement it and have no plans to.** It also `.unwrap()`s on flush and roundtrip (`wl_virtual.rs:146`, `:176`, `:199`, `:204`), panicking on host-compositor disconnect, and it owns a live `EventQueue` whose `commit` is a roundtrip, so it is effectively thread-affine despite the `Send` bound.

uinput is therefore the more portable default; `wl_virtual` is the zero-setup option where it exists. uinput requires `/dev/uinput` write access — either a udev rule with `GROUP="input"` plus `usermod -aG input` and a re-login, or a `TAG+="uaccess"` rule numbered below 73. Note that the `input` group grants read access to *all* input devices, which is a keylogging surface worth stating to the user.

### Capture lifecycle

The portal request fires from `ScreenCastBackend::init` (`pw.rs:156-176`) at screen creation — **eagerly at startup for every monitor**. The PipeWire stream starts lazily, on the first `should_render` where `!is_ready()` (`backend.rs:152-208`).

Dismissal maps only to visibility: `after_input` calls `resume`/`pause` when alpha crosses 0.05 (`backend/openxr/overlay.rs:208-223`). PipeWire honours pause by deactivating the stream (`pipewire/capture.rs:144`), but **`pause()` is an empty no-op in `wlr_screencopy.rs:140`, `xshm.rs:164`, and `wlr_dmabuf.rs:105`** — those backends merely stop being asked. There is no API to stop a capture and release the session.

`docs/host-desktop.md:27` promises capture "can be stopped from Lua… no ongoing cost". That is new work, and AC3.5 depends on it.

### Other gaps against `docs/host-desktop.md`

- `:21` `ext-image-copy-capture-v1`: absent from wlx-capture. Upstream work, out of scope for v1.
- `:39` libei / RemoteDesktop: no trace in the tree. Out of scope; recorded in the design as deferred.
- `:49` per-sink input domains: WayVR has only a global binary `InputFocus { PhysicalScreen, WayVR }` (`input.rs:10`). New work, Task 9.

---

<!-- START_TASK_1 -->
### Task 1: The `lunette-capture` crate and the wlx-capture pin

**Verifies:** None directly; enables all of `lunette-v1.AC3`.

**Files:**
- Modify: `crates/lunette-capture/Cargo.toml`, `src/lib.rs`
- Modify: `Cargo.toml` (workspace dependencies)
- Modify: `CONTRIBUTING.md`

**Step 1: Pin the right thing**

Depend on wlx-capture from the **WayVR repository**, pinned to a revision, using its `wlx-capture` path. Do not depend on `github.com/galister/wlx-capture`: that repo is at 0.5.4, which pulls `ashpd` with `async-std` and a personal fork of pipewire-rs, both of which 0.6.0 has already removed.

`default-features = false, features = ["pipewire"]`. Note in a comment that `pipewire` implies `wayland`, so smithay-client-toolkit arrives regardless, and that dropping `xshm` prunes exactly one crate — feature pruning is not where the weight is.

Record the revision and the reason for pinning the monorepo in a comment, per the rule about commenting non-obvious dependency choices.

**Step 2: Amend `CONTRIBUTING.md`**

`CONTRIBUTING.md:48` says "wlx-capture is a git-pinned external dependency, not a vendor. Fixes to it go upstream." The rule stands, but upstream is now a subdirectory of the WayVR monorepo rather than a standalone repository. Add that clause, so the next person does not "fix" the pin by pointing it at the stale standalone repo.

**Step 3: Verify operationally**

Run: `cargo tree -p lunette-capture | rg -c 'async-std|smol|zbus|ashpd'`
Expected: `0`. If any appear, the wrong version is pinned.

Run: `cargo tree -p lunette-capture --depth 1`
Expected: `pipewire` at 0.10 from crates.io, not a git source.

**Step 4: Commit**

```bash
git add crates/lunette-capture/ Cargo.toml Cargo.lock CONTRIBUTING.md
git commit -m "build: add lunette-capture and pin wlx-capture"
```
<!-- END_TASK_1 -->

<!-- START_SUBCOMPONENT_A (tasks 2-3) -->
<!-- START_TASK_2 -->
### Task 2: Monitor identity

**Verifies:** `lunette-v1.AC3.4`.

**Files:**
- Create: `crates/lunette-capture/src/monitor/name.rs`, `mod.rs`

**Step 1: The type**

Model on niri's `OutputName`, minus the field we cannot obtain:

```rust
pub struct MonitorName {
    connector: Option<String>,
    make: Option<String>,
    model: Option<String>,
}
```

`connector` is `Option` here where niri's is not, because niri always has one and lunette only sometimes does — it comes from `mapping_id`, which two of the three portal backends do not supply usefully.

**Do not derive `PartialEq` or `Eq`.** Identity is decided by a `matches` method, exactly as niri does, and for the same reason: structural comparison of a partially-populated identity is almost always a bug. niri names its ordering helper `compare` rather than implementing `Ord`, with a comment saying so; do the same.

**Step 2: Where the fields come from**

- `make` and `model` from the `wl_output.geometry` event. This is all the protocol offers; **serial is not available to a Wayland client**, which is why `MonitorName` has no serial field and why niri's identity is strictly stronger than ours.
- `connector` from the portal's `mapping_id` when the backend supplies a real one. On xdg-desktop-portal-wlr it is the `wl_output` name, which is the DRM connector name. On GNOME it is a random UUID and must be rejected, and on KDE it is absent.

Detect the useless case rather than storing a UUID as though it were a connector: if `mapping_id` does not match the shape of a connector name, treat it as absent. Record why in a comment, naming `meta-eis.c:526-538` — otherwise this looks like unnecessary defensiveness.

**Step 3: Matching**

`matches(&self, target: &str)`: try `connector` case-insensitively first, then the `"{make} {model}"` descriptor case-insensitively. Connector always wins, as in niri.

**Step 4: The saved key**

`format_descriptor_or_connector()`, following niri's `format_make_model_serial_or_connector` (`output.rs:177-184`): prefer the descriptor, fall back to the connector. The key survives a monitor moving to a different port, and degrades rather than failing when no descriptor exists.

Refresh the stored key when a monitor reattaches and better information is available, as niri does at `workspace.rs:517`.

**Step 5: Duplicate descriptors**

Two identical monitors of the same model are **indistinguishable** to lunette, because we have no serial. This is commoner for us than for niri, not rarer.

Follow niri's rule (`tty.rs:1050-1080`): at enumeration, search for duplicate descriptors and demote the later one to connector-only, with a warning. Insert the check incrementally so successive additions compare against those already added.

Where no connector is available either — GNOME or KDE with two identical monitors — fall back to logical position, and log plainly that identity is positional and will not survive rearrangement. Say so rather than silently picking one; a mirrored monitor attaching to the wrong screen after a restart is confusing in a way an explicit warning is not.

**Step 6: Ordering**

Sort by descriptor before assigning positions, as `Niri::reposition_outputs` does (`src/niri.rs:2700-2760`), so the arrangement does not depend on enumeration order.

**Step 7: Test**

All pure functions, no portal and no GPU. Cover: connector match beats descriptor match; case-insensitivity in both; a UUID-shaped `mapping_id` is rejected; two identical descriptors demote the second; the saved key prefers the descriptor and falls back correctly; a degraded key upgrades on reattach; sort order is independent of insertion order.

**Verification:** `cargo test -p lunette-capture`

**Step 8: Commit**

```bash
git add crates/lunette-capture/src/monitor/
git commit -m "feat(capture): identify monitors by descriptor with connector fallback"
```
<!-- END_TASK_2 -->

<!-- START_TASK_3 -->
### Task 3: Restate AC3.4 and record why

**Verifies:** `lunette-v1.AC3.4` (by correcting it).

**Files:**
- Modify: `docs/design-plans/2026-08-05-lunette-v1.md`
- Modify: `docs/host-desktop.md`
- Modify: `docs/decisions.md`

**Step 1: Restate the criterion**

AC3.4 currently reads:

> Monitors identify themselves by connector name via the portal's `mapping_id`, without the user selecting screens in a prescribed order, and that identity survives a restart.

The mechanism is wrong; the outcome is right. Restate it in terms of the outcome: monitors identify themselves without the user selecting screens in a prescribed order, and that identity survives a restart. Keep both outcome clauses — they are what the criterion is for, and both are achievable.

**Step 2: Correct `docs/host-desktop.md:17`**

It claims lunette implements `mapping_id`-based identification with manual mapping as a fallback. Replace with the geometry-correlation mechanism, noting that `mapping_id` is used opportunistically when a backend supplies a real connector name.

**Step 3: Record the decision**

Add a paragraph to `docs/decisions.md` under "Recorded decisions", in the surrounding style. It must carry the evidence, because `mapping_id` looks like exactly the right tool and someone will propose it again:

- Introduced in ScreenCast v5 to match libei regions, not to name outputs.
- xdg-desktop-portal-wlr sets it to the connector name (`screencast.c:666-668`) — the case that makes it look right.
- mutter sets it to `g_uuid_string_random()` (`meta-eis.c:526-538`) and only under a RemoteDesktop session (`meta-screen-cast-stream.c:426-440`).
- xdg-desktop-portal-kde omits it.
- The portable mechanism is correlating stream `position`/`size` against `wl_output` logical geometry, which is what wlx-overlay-s does.

Also record the ceiling: serial is unavailable over `wl_output`, so lunette's identity is weaker than a compositor's, and two identical monitors of the same model need the positional fallback.

**Step 4: Verify**

Run: `rg -n 'mapping_id' docs/`
Expected: matches only in `decisions.md` and in the opportunistic-use sentence in `host-desktop.md`, never as the stated mechanism.

**Step 5: Commit**

```bash
git add docs/
git commit -m "docs: restate monitor identity in terms of outcome, not mapping_id"
```
<!-- END_TASK_3 -->
<!-- END_SUBCOMPONENT_A -->

<!-- START_TASK_4 -->
### Task 4: Portal session and restore tokens

**Verifies:** `lunette-v1.AC3.4`.

**Files:**
- Create: `crates/lunette-capture/src/portal.rs`
- Create: `crates/lunette-capture/src/tokens.rs`

**Step 1: Request the session**

`SelectSources` with `types` restricted to monitors, `multiple: true` so the user picks every screen in one dialog rather than one per screen, `cursor_mode` as configured, and `persist_mode: 2`.

`multiple: true` is what removes the prescribed order. WayVR's Wayland path uses `allow_multiple: false` and prompts per screen (`pw.rs:93-99`), which is precisely the ritual AC3.4 objects to. Its X11 path already uses `true`.

**Step 2: Correlate streams to monitors**

For each returned stream, read `position` and `size` from the props and match against `wl_output` logical geometry. Take `mapping_id` as a connector name when it passes Task 2's shape check.

Do not rely on stream order. Nothing guarantees it corresponds to selection order or to output enumeration order.

**Step 3: Persist tokens correctly**

The token is **single-use**. Each `Start` invalidates the one supplied and returns a new one. Persist the new token every time, keyed by the monitor's saved identity from Task 2.

Also persist the **granted** `persist_mode` from the `Start` response, not the requested one — backends may downgrade it, and xdg-desktop-portal-wlr does (`screencast.c:171-181`). Storing the requested value produces a config that lies about what will happen next run.

**Step 4: Treat restore as best-effort**

Restore does not guarantee the prompt is skipped, and a rejected token produces no error — the user simply sees a dialog. xdg-desktop-portal-wlr's v1 restore payload carries only `output_name` (`screencast.c:706-711`), so an unplugged or renamed monitor falls back silently. There is a known upstream issue that persist mode does not reliably preserve monitor selection.

Design the flow so a prompt is normal rather than exceptional, and never block a frame waiting for one.

**Step 5: Test**

Token storage and the correlation logic are pure over recorded portal responses. Cover: the new token replaces the old after each `Start`; a downgraded `persist_mode` is stored as granted, not requested; streams correlate to the right monitors given geometry, in any order; a stream matching no known monitor is reported rather than dropped.

Portal round-trips are behind a seam with a fake, per the rule against mocking what you do not own — the portal is an unmanaged dependency and gets a fake, not a real session.

**Verification:** `cargo test -p lunette-capture`

**Step 6: Commit**

```bash
git add crates/lunette-capture/src/portal.rs crates/lunette-capture/src/tokens.rs
git commit -m "feat(capture): drive the screencast portal with persisted restore tokens"
```
<!-- END_TASK_4 -->

<!-- START_TASK_5 -->
### Task 5: Frames to the main thread

**Verifies:** `lunette-v1.AC3.1`.

**Files:**
- Create: `crates/lunette-capture/src/stream.rs`
- Modify: `crates/lunette/src/import/mod.rs`

**Step 1: Forward raw frames**

PipeWire delivers on its own thread through a bare `fn` pointer, not a closure. Convert the `WlxFrame` into a plain owned message and send it up a bounded channel. Every Vulkan import happens on the main thread through the Phase 2 path.

This is the decided approach and it differs from WayVR, which imports inside the callback and therefore needs a second GPU queue, falling back to `MainThreadWlxCapture` when none exists. lunette has one import path and makes no assumption about LÖVR's queue topology — nothing currently exposes it. The cost is a channel hop per frame.

**Step 2: Keep the non-`Send` types on the capture thread**

`ScreenCastManager` polls D-Bus futures with a no-op waker on the calling thread (`pipewire/mod.rs:840`), `DbusFuture` is not `Send` (`mod.rs:632`), and `ScreenCastParams.token` is an `Rc<str>` (`mod.rs:46`). None of these may cross a thread boundary. Construct them inside the capture thread's closure, as Phase 2 does for calloop.

**Step 3: Preserve frame dropping**

`WlxCapture::receive()` is `try_iter().last()` — it deliberately discards stale frames. Keep that: an overlay wants the newest frame, not a backlog. Use a bounded channel with a drop-oldest policy rather than blocking the capture thread, and count drops so the behaviour is observable rather than silent.

**Step 4: Dmabuf frames**

`WlxFrame::Dmabuf` carries up to four `FramePlane { fd, offset, stride }` plus a `FrameFormat` with DRM fourcc and modifier — the exact shape Phase 2's import consumes. The same rules apply: duplicate the fd before import, reject disjoint planes, take the memory type from `vkGetMemoryFdPropertiesKHR`.

`WlxFrame::Implicit` means the frame was already blitted into a buffer we supplied. lunette does not use that path in v1; reject it explicitly rather than ignoring it.

**Step 5: Test**

Frame conversion and the drop policy are pure. Cover: a full channel drops the oldest and increments the counter; a dmabuf frame converts to the import path's input type with planes intact; an `Implicit` frame is rejected with a clear error.

**Verification:** `cargo test -p lunette-capture`

**Step 6: Commit**

```bash
git add crates/lunette-capture/src/stream.rs crates/lunette/src/import/mod.rs
git commit -m "feat(capture): forward frames to the main thread for import"
```
<!-- END_TASK_5 -->

<!-- START_SUBCOMPONENT_B (tasks 6-7) -->
<!-- START_TASK_6 -->
### Task 6: `HidProvider` with a real fallback chain

**Verifies:** `lunette-v1.AC3.3`.

**Files:**
- Create: `crates/lunette-capture/src/hid/mod.rs`, `uinput.rs`, `wl_virtual.rs`

**Step 1: The trait**

Port WayVR's shape (`subsystem/hid/provider/mod.rs:8`): `mouse_move`, `mouse_move_rel`, `send_button`, `wheel`, `set_desktop_extent`, `set_desktop_origin`, `set_modifiers`, `send_key`, `set_keymap`, `commit`. Pointer and button calls accumulate; `commit` flushes once per frame.

**Step 2: Implement the ordered fallback**

This is new work. WayVR has no fallback chain — `HidWrapper::new` (`subsystem/input.rs:22-41`) matches a config enum, calls one initialiser, and installs a dummy on failure. `docs/host-desktop.md:37` describes a chain that does not exist.

Try uinput first, then `wl_virtual`, then a dummy. uinput first because it works under any compositor and under X11; `wl_virtual` second because it is wlroots-only — **KWin and mutter do not implement it and have no plans to**. A configuration switch overrides the order for users who want a specific provider.

When every provider fails, install the dummy and report a structured error naming what was tried and why each failed. WayVR's uinput diagnostic (`uinput.rs:237-266`) is a good model: check the module is loaded, check group membership, give the `usermod` command, note the re-login. Mention that the `input` group grants read access to all input devices, so the user is choosing that knowingly.

**Step 3: Port uinput**

Two `/dev/uinput` handles. The mouse declares `EV_ABS` on `ABS_X`/`ABS_Y` with a fixed normalised range, `EV_REL` hi-res wheels, and `EV_KEY` buttons.

`set_keymap` is a no-op here (`uinput.rs:219`), and that is correct rather than a gap: uinput injects raw keycodes below the compositor, and the host applies its own layout. Say so in a comment, because a silent no-op reads as unfinished.

**Step 4: Port `wl_virtual`, without the panics**

`zwlr_virtual_pointer_v1` and `zwp_virtual_keyboard_v1`, `wl_seat` v4..=9.

Replace the `.unwrap()`s at `wl_virtual.rs:146`, `:176`, `:199`, and `:204`. They panic when the host compositor disconnects, which is a normal event — a host session ending should degrade lunette to the dummy provider with a logged reason, not abort the process.

Its `commit` is a roundtrip on an owned `EventQueue`, so the provider is thread-affine in practice despite the `Send` bound. Keep it on one thread and note why.

Its coordinate handling is better than uinput's: `motion_absolute` takes the extent per call (`wl_virtual.rs:50-56`), so nothing needs recreating on layout change.

**Step 5: Test**

Provider selection is pure given a set of probe results: uinput available selects uinput; uinput unavailable and the wlr protocols present selects `wl_virtual`; neither selects the dummy and produces an error naming both failures; the config override wins.

The providers themselves sit behind the trait; tests use a fake that records the event stream, per the seam rule. Do not open `/dev/uinput` in a test.

**Verification:** `cargo test -p lunette-capture`

**Step 6: Commit**

```bash
git add crates/lunette-capture/src/hid/
git commit -m "feat(capture): inject host input with an ordered provider fallback"
```
<!-- END_TASK_6 -->

<!-- START_TASK_7 -->
### Task 7: Pointer mapping to a physical monitor

**Verifies:** `lunette-v1.AC3.2`.

**Files:**
- Create: `crates/lunette-capture/src/hid/mapping.rs`

**Step 1: The two coordinate spaces**

uinput's device spans the **whole desktop bounding box**, not a monitor, in a fixed normalised range (`uinput.rs:124`):

```rust
let pos = (pos - self.desktop_origin) * (MOUSE_EXTENT / self.desktop_extent);
```

Per-monitor targeting is upstream of that: an affine transform per monitor built from its logical position and size, including rotation and flip (`overlays/screen/backend.rs:93-145`), mapping a hit position on the panel to a global desktop coordinate.

Keep that split. The provider knows only the global desktop; the monitor knows how to reach it.

**Step 2: Use logical geometry**

Not pixel geometry. On a scaled display the two differ by the scale factor, and using pixels puts the cursor in the wrong place by exactly that ratio.

**Step 3: Recompute on hotplug**

Desktop origin and extent change whenever a monitor is added, removed, or moved. WayVR applies them once at screen enumeration (`overlays/screen/wl.rs:114-122`) and nothing observed re-runs it on output change.

Recompute on every output change. The uinput device itself needs no recreation, because its range is normalised and fixed — that is what the 32768 abstraction buys.

**Step 4: Clamp per monitor**

A non-rectangular arrangement leaves dead zones inside the bounding box. Clamp to the target monitor's rectangle before mapping, so a pointer near a panel edge cannot land in a gap between screens.

**Step 5: Note the GNOME uncertainty**

Whether mutter maps a bare `ABS_X`/`ABS_Y` uinput device across the whole layout or onto a single monitor is **unverified**. wlroots spans the layout unless `wlr_cursor_map_to_output` is used, which is opt-in. GNOME may treat an absolute device as tablet-like and bind it to one display.

Record it as a known unknown in `docs/host-desktop.md` and verify on GNOME during Task 10 rather than assuming. If it does bind to one monitor, `wl_virtual` is unavailable there too and the honest answer for GNOME is the libei path, which is out of scope for v1.

**Step 6: Test**

Pure geometry. Cover: a hit at a panel's centre maps to the centre of the target monitor; a scaled monitor maps by logical size, not pixels; a monitor at a non-zero origin offsets correctly; a rotated monitor maps through the transform; clamping keeps a near-edge hit inside the monitor; recomputation after a simulated hotplug produces the new mapping.

**Verification:** `cargo test -p lunette-capture`

**Step 7: Commit**

```bash
git add crates/lunette-capture/src/hid/mapping.rs
git commit -m "feat(capture): map panel hits to physical monitor coordinates"
```
<!-- END_TASK_7 -->
<!-- END_SUBCOMPONENT_B -->

<!-- START_TASK_8 -->
### Task 8: Lazy capture lifecycle

**Verifies:** `lunette-v1.AC3.5`.

**Files:**
- Modify: `crates/lunette-capture/src/stream.rs`, `src/portal.rs`
- Create: `crates/lunette/src/lua/monitor.rs`

**Step 1: Start lazily**

WayVR requests the portal from `ScreenCastBackend::init` (`pw.rs:156-176`) at screen creation — eagerly, for every monitor, at startup. lunette requests only when a monitor is first mirrored.

The first request may prompt, so it must not happen on a frame-critical path. Request, then mirror when the session arrives.

**Step 2: Stop for real**

`docs/host-desktop.md:27` promises capture can be stopped from Lua with no ongoing cost, and AC3.5 requires it. WayVR cannot: dismissal only maps to visibility (`backend/openxr/overlay.rs:208-223`), and `pause()` is an **empty no-op** in `wlr_screencopy.rs:140`, `xshm.rs:164`, and `wlr_dmabuf.rs:105`. Only the PipeWire backend honours it, by deactivating the stream (`pipewire/capture.rs:144`).

Since lunette uses the PipeWire backend, pause is real. But pause is not stop: dismissing a monitor should tear the stream down and drop its resources, keeping the portal session so that re-adding does not re-prompt. Distinguish the two explicitly — `pause` for a temporarily invisible panel, `stop` for a dismissed monitor.

**Step 3: Restart cleanly**

Re-adding a dismissed monitor restarts capture from the retained session and its stored token. If the session has been revoked, fall back to a fresh request, which may prompt.

**Step 4: Expose it to Lua**

`lunette.monitors()`, returning monitor handles, alongside the mirror and dismiss operations on each. Handles follow the standard rules: inert when dead, no raising.

`lunette.monitors()` is not documented anywhere in `docs/` today, even though `lovr.lunmonitoradded` is (`docs/lua-api.md:32`) — there is an event announcing monitors and no way to enumerate them. Phase 6's tier 1 requires creating a panel from a monitor, and by `CONTRIBUTING.md:62` mullion may use only the public API. Document `lunette.monitors()` and the monitor handle's fields, including its identity from Task 2 and its pixel dimensions, in `docs/lua-api.md` in this task.

**Step 5: Test**

Lifecycle transitions against the portal fake: mirroring requests a session once; dismissing stops the stream and retains the session; re-adding restarts without a new request; a revoked session falls back to a fresh request; dismissing twice is idempotent.

**Verification:** `cargo test -p lunette-capture`

**Step 6: Commit**

```bash
git add crates/lunette-capture/src/ crates/lunette/src/lua/monitor.rs
git commit -m "feat(capture): start capture lazily and stop it on dismissal"
```
<!-- END_TASK_8 -->

<!-- START_TASK_9 -->
### Task 9: Input domains

**Verifies:** `lunette-v1.AC3.2`, `lunette-v1.AC3.3`.

**Files:**
- Modify: `crates/lunette-compositor/src/protocol.rs`
- Modify: `crates/lunette/src/lua/sink.rs` (created in Phase 2, Task 11)

**Step 1: The distinction**

Every sink carries a domain: a host sink routes to the `HidProvider` and reaches the host desktop; a window sink routes through the compositor's seat to a client surface. Pointer and key commands dispatch on it.

This is new work. WayVR has only a global binary `InputFocus { PhysicalScreen, WayVR }` (`subsystem/input.rs:10`), toggled for the whole session, which cannot express two hands pointing at different kinds of surface — the thing Phase 5 needs.

**Step 2: Make it a type, not a flag**

An enum on the sink, so routing is an exhaustive match and a new domain cannot be silently unhandled. `docs/host-desktop.md:49` also requires Lua to be able to query it.

**Step 3: Keyboard focus**

A key event to a host sink reaches whatever the host compositor focuses — lunette does not choose, and must not try. A key event to a window sink goes to that window through its seat. AC3.3 is the first case; Phase 5 builds the second.

**Step 4: Test**

Routing is pure given a sink and a domain. Cover: a pointer to a host sink reaches the provider and not the compositor; a pointer to a window sink reaches the compositor and not the provider; two sinks in different domains route independently in the same frame; Lua can read the domain.

**Verification:** `cargo test -p lunette-capture`, `cargo test -p lunette-compositor`, and `cargo test -p lunette` — this task modifies `crates/lunette/src/lua/sink.rs`, so the binary crate's tests must run too.

**Step 5: Commit**

```bash
git add crates/lunette-compositor/src/protocol.rs crates/lunette/src/lua/sink.rs
git commit -m "feat: route input by sink domain"
```
<!-- END_TASK_9 -->

<!-- START_TASK_10 -->
### Task 10: Check suite and human gates

**Verifies:** All Phase 4 criteria, observationally.

**Step 1: Run the check suite**

All five commands from `CONTRIBUTING.md:171-175`, inside `nix develop`.

**Step 2: Confirm the dependency shape**

Run: `cargo tree | rg -c 'async-std|ashpd'`
Expected: `0`. A non-zero result means the 0.5.4 wlx-capture crept back in.

**Step 3: The human gates**

None of these is automatable; all are recorded in `test-requirements.md`.

- A mirrored monitor appears with a texture matching the captured output's resolution (AC3.1).
- Pointing at a mirrored monitor moves the host cursor to the corresponding position on that physical display (AC3.2). Check on a scaled display and on a monitor at a non-zero origin — those are where the mapping breaks.
- Keystrokes reach whatever the host focuses (AC3.3).
- Monitors are selected once, in one dialog, in any order, and reattach correctly after a restart (AC3.4).
- Dismissing a mirror stops its stream; re-adding restarts it without re-prompting (AC3.5).

**Step 4: Verify the GNOME unknown**

Test pointer mapping under GNOME specifically. It is unverified whether mutter maps a bare absolute uinput device across the whole layout or binds it to one monitor. If it binds to one, record it plainly: `wl_virtual` is also unavailable on GNOME, so the honest answer there is libei, which v1 does not implement.

**Step 5: Record the findings**

Append to `docs/milestone-0-findings.md`: which portal backend was tested and what it put in `mapping_id`; whether restore actually avoided a prompt on the second run; whether the uinput mapping was correct on a scaled or rotated display; and the GNOME result.

**Step 6: Commit**

```bash
git add docs/milestone-0-findings.md
git commit -m "docs: record monitor mirroring findings"
```
<!-- END_TASK_10 -->

---

## Done when

- A mirrored monitor appears as a panel with a texture matching its resolution.
- The host cursor follows a laser to the right position on the right physical display, including on scaled and offset monitors.
- Keystrokes reach the host.
- Monitors are chosen once in a single dialog, in any order, and reattach correctly after a restart.
- Dismissing a mirror stops its capture; re-adding restarts it.
- `cargo tree` shows no `async-std` and no `ashpd`.
- All five check commands pass.

## Deliberately not in this phase

- `ext-image-copy-capture-v1` (`host-desktop.md:21`). Absent from wlx-capture; upstream work.
- libei via `org.freedesktop.portal.RemoteDesktop` (`host-desktop.md:39`). The right answer for GNOME and KDE where `wl_virtual` is unavailable, and the only context in which `mapping_id` is meaningful. Out of scope for v1, and the reason should be recorded so the GNOME limitation is understood rather than rediscovered.
- Clipboard bridging — Phase 5.
- Drag and drop (`host-desktop.md:66`).
- Serial-based monitor identity, which would require DRM access lunette does not have as a Wayland client.

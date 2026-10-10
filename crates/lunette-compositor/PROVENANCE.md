# Provenance

This crate is a hard vendor of WayVR's `wayvr/src/backend/wayvr/`, roughly 4.4k lines of smithay wiring. It carries WayVR's copyright and licence. See [CREDITS.md](../../CREDITS.md) for the credit, and [docs/dev/compositor.md](../../docs/dev/compositor.md) for why the code is vendored rather than tracked upstream.

## Upstream

| | |
|---|---|
| Repository | `https://github.com/wayvr-org/wayvr` |
| Commit | `98f800c644719d3f23a20e50bd3237c29a8082cb` |
| Licence | GPL-3.0-only |
| Authors | galister, oo8dev |

`wayvr/Cargo.toml:8` gives the repository as `https://github.com/wlx-team/wayvr`, and the README links `wayvr-org/wayvr`. The first redirects to the second with a 301, and the clone's own origin is `wayvr-org`, so `wayvr-org/wayvr` is canonical. Headers use it.

The commit is recorded per file rather than once for the crate. WayVR has no release tags, the ported files diverge from upstream as lunette changes them, and a fix worth taking from upstream is diffed against the commit that file came from.

## The header form

WayVR carries no licence or copyright headers. A recursive grep for `Copyright` and `SPDX` across its `.rs` files returns nothing, so there is nothing to preserve. The headers below are authored, from the metadata in `wayvr/Cargo.toml:5-6`.

Every file ported from WayVR begins with:

```rust
//! Ported from WayVR (https://github.com/wayvr-org/wayvr), backend/wayvr/comp.rs, at commit 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
```

The upstream path is relative to `wayvr/src/`. A file assembled from more than one upstream file names each of them.

`crates/lunette` is not covered by this. Only files in this crate, and any file elsewhere that takes WayVR code, carry the header.

## Where each upstream file lands

| Upstream | lunette |
|---|---|
| `backend/wayvr/comp.rs` at `42e9deb54cc5c36037b49237867afa3dc4593f4a` | `src/wayvr/comp.rs` |
| `backend/wayvr/mod.rs` (`WvrServerState::new`, `WayVRTask`, the drag-and-drop pointer tracking, and `SurfaceBufWithImage`) at `42e9deb54cc5c36037b49237867afa3dc4593f4a` | `src/wayvr/mod.rs` |
| `backend/wayvr/window.rs` at `42e9deb54cc5c36037b49237867afa3dc4593f4a`, `backend/wayvr/mod.rs` (the size-constraint fragment) | `src/wayvr/window.rs` |
| `backend/wayvr/mod.rs` (the seat construction fragment), `backend/wayvr/window.rs` (the hover state), `backend/wayvr/client.rs` (the `seat_keyboard` and `seat_pointer` fields) | `src/seat.rs` |
| `backend/wayvr/hit_test.rs` at `42e9deb54cc5c36037b49237867afa3dc4593f4a` | `src/wayvr/hit_test.rs` |
| `backend/wayvr/process.rs` at `42e9deb54cc5c36037b49237867afa3dc4593f4a` | `src/wayvr/process.rs` |
| `backend/wayvr/mod.rs` (`spawn_process`, `add_external_process`, and the process tick in `tick_events`) at `42e9deb54cc5c36037b49237867afa3dc4593f4a` | `src/spawn/table.rs` |
| `backend/wayvr/mod.rs` (`configure_env` and `generate_auth_key`) at `42e9deb54cc5c36037b49237867afa3dc4593f4a` | `src/spawn/plan.rs` |
| `backend/wayvr/client.rs` at `42e9deb54cc5c36037b49237867afa3dc4593f4a`, `backend/wayvr/mod.rs` (`WaylandEnv`) | `src/wayvr/client.rs` |
| `backend/wayvr/image_importer.rs` (the `wl_shm` path) | `crates/lunette/src/import/shm.rs` |

`hit_test.rs` comes across without its two couplings. The `Arc<ImageView>` on `RenderedSurface` is read only for a size, so it is left out and the image stays with whoever draws, which keeps this crate free of a graphics dependency. `PointerHit`, `hit_target`, `panel_hit_from_hit`, the UV conversions, and the panel height go entirely, because Lua performs the ray intersection and hands down pixel coordinates ([docs/dev/input.md](../../docs/dev/input.md)), and `hit_target_at` is the operation that remains. The transforms are always built without server-side decorations, which makes them the identity. `BORDER_SIZE` and `BAR_SIZE` stay only because `compute_transforms` names them; drawing decorations is the job of the `desktop/decorations` consumer. The `has_alpha`, `source_uv`, and `surface_id` fields and `rendered_surfaces_dirty` serve upstream's renderer and are left out.

`process.rs` keeps upstream's shape: the `Process` enum over `WayVRProcess` and `ExternalProcess`, the `ProcessHandle` slotmap key, `get_process_env_value`, and `find_by_pid`. A managed process holds its child behind the `ChildProcess` seam in `src/spawn/system.rs` rather than a `std::process::Child`. That seam is lunette's own: the child leads its own process group, receives `SIGTERM` through `PR_SET_PDEATHSIG` if lunette dies, has its output captured without blocking, and is never signalled after it has been reaped, which replaces upstream's `Drop for WayVRProcess`. `get_process_env_value` reads the environment as bytes, `find_by_pid` takes the `/proc` seam and compares the token in constant time, and the application metadata, `get_name`, `KillSignal`, and the `wayvr_ipc` packet conversions are left out.

`client.rs` keeps upstream's `WayVRClient`, `add_client`, `cleanup_clients`, `accept_connection`, the listener in `create_wayland_listener`, `bundled_executable`, and the input methods `send_key`, `set_keymap`, `send_mouse_move`, `send_pointer_button`, and `send_pointer_axis_wheel_raw`. lunette's event loop owns the display and the listening socket and the compositor state owns the clients, so the client methods belong to the state, and a connection is accepted when calloop reports it rather than polled from `tick_wayland`. lunette serves several seats, so `WayVRCompositor` is one seat's view: it borrows the state and holds that seat's `seat_keyboard` and `seat_pointer`, which `src/seat.rs` keeps per seat, and the input method bodies run against it unchanged. Its timestamps come from the compositor clock rather than `time.rs`. The listener writes neither the environment nor `wayvr.disp`, and the satellite runs behind the spawner seam in its own process group, which replaces upstream's `Drop`. `release_all_keys`, `send_pointer_axis_wheel_accumulated`, `accumulate_discrete_scroll`, `cleanup_handles`, and `get_wayvr_env_from_pid` are left out; `find_by_pid` replaces the last. The `Command` glue around these methods, with hover, keyboard focus, explicit modifiers, typed text, and continuous scrolling, is lunette's own in `src/commands/input.rs`.

`comp.rs` keeps upstream's `Application`, its handler impls in upstream's order, and the `delegate_*!` macros. `Application` also holds what lunette's features need: several seats and outputs, the host clipboard bridge, frame pacing, process attribution, and the ends of the event and snapshot transports. Its `commit` keeps upstream's match over the buffer type, but the images live on the frame thread, so each import is reported as an event and `SurfaceBufWithImage` keeps only the image's size. The `wl_shm` path copies the buffer from its offset in the pool, a retained dmabuf is released when anything else replaces it but not when the same buffer is committed again, a buffer of an unknown type is released, and a popup whose initial configure fails is logged rather than a panic. The decoration handlers record the mode each toplevel asked for, as upstream does. smithay's `Output`, `delegate_output!`, `set_clipboard_text`, the redraw requests, the single-pixel buffer, and the relative pointer are left out, and lunette adds `new_surface`, `destroyed`, `app_id_changed`, and the fractional-scale and content-type globals.

`mod.rs` keeps the fragments of upstream's `mod.rs` that lunette uses: `WvrServerState::new` as `Application::new`, the `WayVRTask` queue the handlers fill, the drag-and-drop pointer tracking, keyed by seat, and `SurfaceBufWithImage` in the surface data map, whose content can now be cleared by a null-buffer commit. lunette drains the task queue after each dispatch in `src/commands/mod.rs`, where upstream drains it in `tick_events`. `image_importer.rs`, `input_capture.rs`, and `time.rs` are not in `src/wayvr`; the paragraphs below say why.

Thirty-one files carry no header, and the check is `rg --files-without-match 'Ported from WayVR' crates/lunette-compositor/src/` against this list. The check and the list reconcile exactly; a file appearing in one and not the other is the defect this list exists to catch.

- `src/protocol/mod.rs`, `src/protocol/input.rs`, `src/protocol/keymap.rs`, `src/protocol/process.rs`, `src/thread.rs`, `src/testing.rs`, `src/test_client/mod.rs`, `src/test_client/driver.rs`, and `src/test_client/selection.rs` are lunette's own. WayVR has no equivalent: its compositor runs on the caller's thread, driven per-tick from `mod.rs`, and it has no cross-thread protocol to define.
- `src/lib.rs` declares the crate's modules and states its boundary. It takes no code from upstream.
- `src/commands/mod.rs`, `src/commands/input.rs`, and `src/commands/processes.rs` are lunette's own. They apply the commands from the main thread, call the input methods in `src/wayvr/client.rs` for the delivery, run the spawn and signal commands and the process poll timer, and drain the task queue of `src/wayvr/mod.rs` into lunette's window bookkeeping. The client attribution is in `src/wayvr/client.rs`.
- `src/config.rs` is lunette's own: the compositor's configuration and its default seat and output.
- `src/surface.rs` is lunette's own: the surface identifiers, the graphics importer seam, and the bookkeeping a commit does for lunette's windows and the frame thread.
- `src/keymap.rs` and `src/type_text.rs` are new. WayVR's keymap handling is forward-only and draws key legends; it has no reverse lookup and nothing that synthesises a keymap for arbitrary text.
- `src/selection/mod.rs`, `src/selection/host.rs`, `src/selection/data_control/mod.rs`, `src/selection/data_control/objects.rs`, and `src/selection/seat.rs` are new. WayVR serves the same four selection protocols to its own clients — the `SelectionHandler`, `DataDeviceHandler`, and `PrimarySelectionHandler` impls in `src/wayvr/comp.rs` are ported and carry the header — but it never speaks data control to the host, so nothing bridges a selection across the boundary upstream.
- `src/output.rs` is new. WayVR advertises one `wl_output` for everything (`mod.rs:209`) and clamps every window to its bounds, so there is no registry of virtual monitors upstream, no per-client filtering of the globals, and no rescale fanout to port.
- `src/pacing.rs` is new. WayVR answers every accumulated frame callback on every tick (`comp.rs:151-160`); the rate policy, the withholding, and the timer that wakes the loop for a withheld surface have no upstream counterpart.
- `src/graphics.rs` is new. WayVR's compositor is constructed against a graphics device that outlives it, so it never gives one up and takes another.
- `src/spawn/mod.rs`, `src/spawn/system.rs`, and `src/spawn/inspect.rs` are lunette's own: the spawner and `/proc` seams, process groups, parent-death signalling, and output capture, none of which WayVR has.
- `src/spawn/tests.rs`, `src/commands/tests.rs`, and `src/selection/tests.rs` are lunette's tests for ported and new code alike. WayVR ships none.

### The methods carved out of the old `state/compositor.rs`

The state that `src/wayvr/comp.rs` now holds once lived in `state/compositor.rs`, and its lunette-only methods now sit beside the state they change: the process commands in `src/commands/processes.rs`, the output commands in `src/output.rs`, frame pacing in `src/pacing.rs`, the selection bridge in `src/selection/seat.rs`, and the graphics handover in `src/graphics.rs`. Whether the header travels with a method is decided per file rather than by where the code came from, and the answers are recorded here so they are not re-derived.

- `src/commands/processes.rs` carries no header. The client attribution that took upstream's names moved to `src/wayvr/client.rs`, and what remains, spawning, signalling, and the poll timer, drives the process table in `src/spawn/table.rs`, which carries the header for the upstream fragments.
- `src/output.rs` carries no header. Everything in it is about virtual monitors, which WayVR does not have. `logical_size` moved across from the ported file and is lunette's own: it converts lunette's `PixelSize` newtype.
- `src/pacing.rs` carries no header. The rate policy and the wakeup timer are new, and `send_frame_callbacks` is a rewrite around them rather than the drain WayVR performs. `Application::millis` is the one thing here with an upstream counterpart, and it is not a port of it — see the `time.rs` paragraph below. lunette's clock is monotonic because WayVR's is not.

`MouseIndex` (`mod.rs:154`) is not ported. `protocol::PointerButton` covers it and covers the two side buttons WayVR omits.

`time.rs` is not ported either, though an earlier version of this file recorded it as folded into `Application::millis`. The two answer the same question and share no code. WayVR reads `SystemTime::now().duration_since(UNIX_EPOCH)` and unwraps it, giving a `u64` of wall-clock milliseconds; `Application::elapsed` reads `Instant::elapsed` from the moment the compositor started, and `protocol_millis` truncates to the `u32` the protocol carries. Wayland's timestamps must be monotonic and a wall clock is not, which is why `Application::elapsed` in `src/pacing.rs` reads a monotonic clock. It is a contrast, not a derivation.

`image_importer.rs` is the exception to the rule that ported code lives here. Its dmabuf path is replaced by lunette's own `ash` import, and its `wl_shm` path lands in `crates/lunette`, because this crate must not gain a GPU dependency.

`input_capture.rs` is not ported. It grabs the host's own keyboard and pointer devices through libinput and evdev, which is host desktop integration rather than compositor work, and it belongs to no phase of v1.

Parts of the ported files are deliberately dropped rather than translated: the single-pixel-buffer handling in `comp.rs`, and the `wayvr_ipc` packet conversions, the hover and keyboard-focus state, and the unused `visible`, `resizable`, and `checked_configure_size` in `window.rs`. Each drop is recorded as a comment at the site it would otherwise have occupied.

## House style

Vendored code is exempt from the house style in [CONTRIBUTING.md](../../CONTRIBUTING.md) until it is rewritten. Reformatting it wholesale destroys the ability to diff against upstream. Bring a file up to house style when a change touches it substantially, not in drive-by churn.

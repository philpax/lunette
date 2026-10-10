# Provenance

This crate vendors WayVR's `wayvr/src/backend/wayvr/`, about 4.75k lines of smithay wiring at the recorded commit. It carries WayVR's copyright and licence. See [CREDITS.md](../../CREDITS.md) for the credit, and [docs/dev/compositor.md](../../docs/dev/compositor.md) for why the code is vendored rather than taken as a dependency.

## Upstream

| | |
|---|---|
| Repository | `https://github.com/wayvr-org/wayvr` |
| Commit | `42e9deb54cc5c36037b49237867afa3dc4593f4a` |
| Licence | GPL-3.0-only |
| Authors | galister, oo8dev |

`wayvr/Cargo.toml:8` gives the repository as `https://github.com/wlx-team/wayvr`, and the README links `wayvr-org/wayvr`. The first redirects to the second with a 301, and the clone's own origin is `wayvr-org`, so `wayvr-org/wayvr` is canonical.

`backend/wayvr` has not changed upstream since `5517c3a809bcee4ea64e298d476255a25b83c380` (30 September 2026). WayVR has no release tags. Every ported file was taken at the one commit, and a fix worth taking from upstream is diffed against it.

## The layout

The files under `src/wayvr/` are upstream's files, under upstream's names, with upstream's identifiers: `Application`, `WayVRCompositor`, `WayVRClient`, `WayVRTask`, `popup_manager`, `SurfaceBufWithImage`, and the rest. They keep as much of upstream's text as lunette can, so that

```sh
diff -r <wayvr>/wayvr/src/backend/wayvr crates/lunette-compositor/src/wayvr
```

reads as lunette's patch against WayVR. Commit `fff5975` added the upstream files verbatim, so `git diff fff5975 -- crates/lunette-compositor/src/wayvr` shows the same patch from inside the repository. `rustfmt.toml` excludes the directory, because the house import style would reformat upstream's lines; edits there follow upstream's formatting by hand. The files use `slotmap` and `glam` as upstream does, and alias `tracing` as `log` so that upstream's logging lines stay unchanged.

Everything outside `src/wayvr/` is lunette's own: the thread and its channel protocol, the command dispatch, per-client outputs, several seats, frame pacing, the selection bridge, the graphics handover, the spawner and `/proc` seams, keymap synthesis for typed text, and the test infrastructure. A few of those files contain logic that follows an upstream fragment; the table below names them.

## The header

WayVR carries no licence or copyright headers. A recursive grep for `Copyright` and `SPDX` across its `.rs` files returns nothing, so there is nothing to preserve. The header is authored, from the metadata in `wayvr/Cargo.toml:5-6`.

Every file under `src/wayvr/` begins with:

```rust
//! Adapted from WayVR's `backend/wayvr/comp.rs` at commit
//! 42e9deb54cc5c36037b49237867afa3dc4593f4a.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
```

The upstream path is relative to `wayvr/src/`. A file that also takes a fragment of another upstream file names it. No file outside `src/wayvr/` carries the header. The rule is a directory rule, and two searches check it; both print nothing when it holds:

```sh
rg --files-without-match 'Copyright \(c\) the WayVR authors' crates/lunette-compositor/src/wayvr
rg --files-with-matches 'Copyright \(c\) the WayVR authors' crates/lunette-compositor/src --glob '!crates/lunette-compositor/src/wayvr'
```

## Where each upstream file lands

| Upstream `backend/wayvr/` | lunette |
|---|---|
| `client.rs` | `src/wayvr/client.rs` |
| `comp.rs` | `src/wayvr/comp.rs` |
| `hit_test.rs` | `src/wayvr/hit_test.rs` |
| `mod.rs` | `src/wayvr/mod.rs` |
| `process.rs` | `src/wayvr/process.rs` |
| `window.rs` | `src/wayvr/window.rs` |
| `image_importer.rs` | not ported |
| `input_capture.rs` | not ported |
| `time.rs` | not ported |

Upstream's `mod.rs` holds `WvrServerState`, which runs the whole backend from WayVR's overlay tick. lunette keeps its fragments where the code that uses them lives:

| Fragment of upstream `mod.rs` | lunette |
|---|---|
| `WvrServerState::new`, `WayVRTask`, and `SurfaceBufWithImage` | `src/wayvr/mod.rs` |
| `WaylandEnv` | `src/wayvr/client.rs` |
| The size constraints read in `tick_events` | `src/window.rs` |
| The seat construction | `src/seat.rs` |
| `configure_env` and `generate_auth_key` | `src/spawn/plan.rs` |
| `spawn_process`, `add_external_process`, and the process tick in `tick_events` | `src/spawn/table.rs` |
| The task drain in `tick_events` | `src/commands/mod.rs` |

The `wl_shm` repacking of `image_importer.rs` is in `crates/lunette/src/import/shm.rs`, outside this crate, because the frame thread performs every upload and this crate has no graphics dependency.

## What lunette changes in the ported files

`comp.rs` keeps `Application`, its handler impls in upstream's order, and the `delegate_*!` macros. `Application` also holds what lunette's features need, in fields after upstream's: several seats and outputs, the host clipboard bridge, frame pacing, process attribution, and the ends of the event and snapshot transports. `commit` keeps upstream's match over the buffer type, but the images live on the frame thread, so each import is reported as an event and `SurfaceBufWithImage` keeps only the image's size. A buffer of an unknown type is released, and a retained dmabuf is released when anything else replaces it but not when the same buffer is committed again. The `wl_shm` copy and the content-type conversion that `commit` calls are in `src/surface.rs`, and the accessors for the output assignment that `ClientState` carries are in `src/output.rs`. The decoration handlers record the mode each toplevel asks for, as upstream does, and the window snapshot reports it. The drag-and-drop handlers record the drag on the seat smithay names, through `begin_drag` and `end_drag` in `src/drag.rs`, where upstream's guess the pointer from the one that pressed last and queue a task for the overlay. lunette adds `new_surface`, `destroyed`, `app_id_changed`, and the fractional-scale and content-type globals.

`mod.rs` keeps the state's construction, the `WayVRTask` queue the handlers fill, and `SurfaceBufWithImage` in the surface data map, whose content a null-buffer commit clears. Its `logical_size` and `source_uv` are upstream's, read from the buffer extent after a quarter turn has exchanged its axes. lunette drains the task queue after each dispatch, in `src/commands/mod.rs`, where upstream drains it in `tick_events`. The drain sends a new toplevel's initial configure with the output's bounds only, where upstream's also carries a size and the activated state, and reads the title and app id at that point. A toplevel whose client has disconnected cannot queue its removal, so its window is removed at once.

`window.rs` keeps `Window`, `WindowManager`, `PendingConfigure`, `CreateWindowParams`, the clamp, and the serial-checked `remember_committed_size`. Each window also carries the identifiers lunette mints for Lua, its output, its title and app id, its states, its content type, and its source crop. lunette's methods over those fields, the window snapshot, and the lookups by lunette's identifiers are in `src/window.rs`. The client's size limits are read again at every commit rather than once at creation.

`hit_test.rs` keeps `hit_target_at` and the surface-tree walk. Lua performs the ray intersection and hands down pixel coordinates ([docs/dev/input.md](../../docs/dev/input.md)), so the panel, UV, and image parts are left out, and the transforms are built without server-side decorations, which makes them the identity.

`process.rs` keeps the `Process` enum over `WayVRProcess` and `ExternalProcess`, the `ProcessHandle` key, `get_process_env_value`, and `find_by_pid`. A managed process holds its child behind the `ChildProcess` seam in `src/spawn/system.rs`: the child leads its own process group, receives `SIGTERM` through `PR_SET_PDEATHSIG` if lunette dies, and has its output captured without blocking. `find_by_pid` takes the `/proc` seam and compares the 256-bit token in constant time, where upstream compares a UUID.

`client.rs` keeps `WayVRClient`, `add_client`, `cleanup_clients`, `accept_connection`, the listener, `bundled_executable`, and the input methods. lunette's event loop owns the display and the listening socket, so a connection is accepted when calloop reports it rather than polled from `tick_wayland`, and the client methods belong to `Application`. lunette serves several seats, so `WayVRCompositor` is one seat's view: it borrows the state and holds that seat's keyboard and pointer, and upstream's input method bodies run against it. The listener writes neither the environment nor `wayvr.disp`, and the satellite runs behind the spawner seam in its own process group.

## Deliberate drops

These parts of upstream are left out because lunette has no use for them or replaces them:

- `image_importer.rs`. lunette imports dmabufs with its own `ash` path and repacks `wl_shm` buffers on the frame thread, and this crate must not gain a GPU dependency.
- `input_capture.rs`. It grabs the host's own keyboard and pointer through libinput and evdev, which is host desktop integration rather than compositor work.
- `time.rs`. Its clock is wall-clock time, and Wayland timestamps must be monotonic. `Application::elapsed` in `src/pacing.rs` reads a monotonic clock instead.
- The overlay, IPC, and input-capture parts of `WvrServerState`, the `wayvr_ipc` packet conversions, the application metadata, `get_name`, and `KillSignal`.
- smithay's `Output` and `delegate_output!`. lunette's own `wl_output` global in `src/output.rs` filters outputs per client.
- `set_clipboard_text` and the redraw requests. The selection bridge and the snapshot's dirty flag replace them.
- `MouseIndex`, `MouseState`, the window's keyboard focus, `visible`, `resizable`, and `checked_configure_size`. `protocol::PointerButton` covers `MouseIndex` and the two side buttons it omits, and hover and focus are per seat in `src/seat.rs`.
- `release_all_keys`, `send_pointer_axis_wheel_accumulated`, `accumulate_discrete_scroll`, `cleanup_handles`, `accept_connections`, `tick_wayland`, `export_display_number`, and `get_wayvr_env_from_pid`. `find_by_pid` replaces the last.
- `PointerHit`, `hit_target`, `panel_hit_from_hit`, the UV conversions, the panel height, and the `image`, `source_uv`, `has_alpha`, and `surface_id` fields of `RenderedSurface`.
- `vr_pointer`, `pointer_button_owner`, `dnd_pointer`, `set_vr_pointer`, `set_vr_pointer_button`, and the `DndStarted` and `DndDropped` tasks. WayVR's pointers share one smithay seat, so it infers which pointer a drag belongs to. lunette's seats are smithay's, and the drag handlers receive the seat, so `src/drag.rs` records each drag on its own seat when the handler runs. The icon overlay of upstream's `overlays/drag_item.rs` is the Lua laser's to draw.
- The `Drop` impls of `WayVRProcess` and `WayVRCompositor`. The spawner seam terminates and reaps a child when its handle drops.

## Upstream defects lunette fixes

Each of these is a defect in WayVR at the recorded commit, fixed in lunette, and a candidate for an upstream pull request:

- `image_importer.rs` reads a `wl_shm` buffer from the base of its pool and ignores the buffer's offset, so a client that keeps several buffers in one pool shows the wrong pixels. lunette copies from the offset and checks that the buffer fits the pool.
- `get_process_env_value` reads `/proc/<pid>/environ` with `read_to_string`, which fails on any environment that is not UTF-8, so the client is never attributed. lunette reads it as bytes.
- `Drop for WayVRProcess` sends `SIGTERM` to the child's pid even after `try_wait` has reaped it, so it can signal an unrelated process that reused the pid. lunette never signals a reaped child.
- `SurfaceBufWithImage::logical_size` ignores the buffer transform, so a quarter-turned buffer reports its axes exchanged. lunette exchanges them before computing the size, the source crop, and the viewport check.
- `time.rs` reads `SystemTime`, which can go backwards, for Wayland timestamps, which must not. lunette reads a monotonic clock.
- The popup commit path calls `popup.send_configure().expect("initial configure failed")`, so a client whose popup cannot be configured panics the compositor. lunette logs it.
- `comp.rs` delegates `wp_single_pixel_buffer_manager_v1` and handles the buffer type in `commit`, but never creates the global, so no client can create such a buffer. lunette creates it.

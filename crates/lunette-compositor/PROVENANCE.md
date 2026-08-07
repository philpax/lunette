# Provenance

This crate is a hard vendor of WayVR's `wayvr/src/backend/wayvr/`, roughly 4.4k lines of smithay wiring. It carries WayVR's copyright and licence. See [CREDITS.md](../../CREDITS.md) for the credit, and [docs/compositor.md](../../docs/compositor.md) for why the code is vendored rather than tracked upstream.

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
| `backend/wayvr/comp.rs` (the state and globals), `backend/wayvr/mod.rs` (the globals and output fragments) | `src/state/compositor.rs` |
| `backend/wayvr/comp.rs` (the handler impls and `delegate_*!`) | `src/state/handlers.rs` |
| `backend/wayvr/comp.rs` (`CompositorHandler::commit`) | `src/state/commit.rs` |
| `backend/wayvr/mod.rs` (the seat and pointer command paths), `backend/wayvr/client.rs` (the input methods) | `src/state/input.rs` |
| `backend/wayvr/mod.rs` (the surface-buffer fragments) | `src/surface.rs` |
| `backend/wayvr/window.rs`, `backend/wayvr/mod.rs` (the size-constraint fragment) | `src/window.rs` |
| `backend/wayvr/mod.rs` (the seat construction fragment), `backend/wayvr/window.rs` (the hover state) | `src/seat.rs` |
| `backend/wayvr/hit_test.rs` | `src/hit_test.rs` |
| `backend/wayvr/client.rs` (`accept_connection` and `cleanup_clients`), `backend/wayvr/mod.rs` (the spawn fragment) | `src/state/processes.rs` |
| `backend/wayvr/process.rs` (the registry and attribution), `backend/wayvr/mod.rs` (the spawn fragments) | `src/process/registry.rs` |
| `backend/wayvr/process.rs` (spawning and signalling) | `src/process/spawn.rs` |
| `backend/wayvr/process.rs` (`get_process_env_value`) | `src/process/attribution.rs` |
| `backend/wayvr/client.rs`, `backend/wayvr/mod.rs` (`WaylandEnv`, `ExternalProcessRequest`) | `src/client.rs` |
| `backend/wayvr/image_importer.rs` (the `wl_shm` path) | `crates/lunette/src/import/shm.rs` |

`hit_test.rs` comes across without its two couplings. The `Arc<ImageView>` on `RenderedSurface` is read only for a size, so the size arrives as a value and the image stays with whoever draws — which is what keeps this crate free of a graphics dependency. `PointerHit`, the UV transform, and the panel layer go entirely, because Lua performs the ray intersection and hands down pixel coordinates ([docs/input.md](../../docs/input.md)). `BORDER_SIZE` and `BAR_SIZE` are WayVR's titlebar chrome and are mullion's job.

`comp.rs` and `process.rs` each land in more than one file because a single one
would be past the size threshold in [CONTRIBUTING.md](../../CONTRIBUTING.md).
The split is along a seam, not at the line limit: the state, the handlers hung
off it, and the commit path answer different questions.

`mod.rs` is 1391 lines of which only fragments are wanted, so it lands in several files rather than one. Each names the fragments it took.

Twenty-six files carry no header, and the check is `rg --files-without-match 'Ported from WayVR' crates/lunette-compositor/src/` against this list. The check and the list reconcile exactly; a file appearing in one and not the other is the defect this list exists to catch.

- `src/protocol/mod.rs`, `src/protocol/input.rs`, `src/protocol/keymap.rs`, `src/protocol/process.rs`, `src/thread.rs`, `src/testing.rs`, `src/test_client/mod.rs`, `src/test_client/driver.rs`, and `src/test_client/selection.rs` are lunette's own. WayVR has no equivalent: its compositor runs on the caller's thread, driven per-tick from `mod.rs`, and it has no cross-thread protocol to define.
- `src/lib.rs` declares the crate's modules and states its boundary. It takes no code from upstream.
- `src/keymap.rs` and `src/type_text.rs` are new. WayVR's keymap handling is forward-only and draws key legends; it has no reverse lookup and nothing that synthesises a keymap for arbitrary text.
- `src/selection/mod.rs`, `src/selection/host.rs`, `src/selection/data_control/mod.rs`, `src/selection/data_control/objects.rs`, and `src/state/selection.rs` are new. WayVR serves the same four selection protocols to its own clients — the `SelectionHandler`, `DataDeviceHandler`, and `PrimarySelectionHandler` impls in `src/state/handlers.rs` are ported and carry the header — but it never speaks data control to the host, so nothing bridges a selection across the boundary upstream.
- `src/output.rs` and `src/state/outputs.rs` are new. WayVR advertises one `wl_output` for everything (`mod.rs:209`) and clamps every window to its bounds, so there is no registry of virtual monitors upstream, no per-client filtering of the globals, and no rescale fanout to port.
- `src/pacing.rs` and `src/state/pacing.rs` are new. WayVR answers every accumulated frame callback on every tick (`comp.rs:151-160`); the rate policy, the withholding, and the timer that wakes the loop for a withheld surface have no upstream counterpart.
- `src/state/graphics.rs` is new. WayVR's compositor is constructed against a graphics device that outlives it, so it never gives one up and takes another.
- `src/process/tests.rs`, `src/state/tests.rs`, `src/hit_test/tests.rs`, and `src/selection/tests.rs` are lunette's tests for ported and new code alike. WayVR ships none.

### The files carved out of `state/compositor.rs`

`state/compositor.rs` carries the header, and a split moved three groups of methods out of it into `state/outputs.rs`, `state/pacing.rs`, and `state/processes.rs`. Whether the header travels with a method is decided per file rather than by where the code came from, and the answers are recorded here so they are not re-derived.

- `src/state/processes.rs` carries the header. `attach_client` reads the connecting client's credentials and attributes it, and `prune_clients` sweeps clients that have disconnected; those are `client.rs:158-192` and `client.rs:129-141`. The distinctive part of the attribution — matching a process by the token in its environment — is in `src/process/registry.rs`, which carries its own header, but the sequence around it is WayVR's.
- `src/state/outputs.rs` carries no header. Everything in it is about virtual monitors, which WayVR does not have. `logical_size` and `send_initial_surface_state` moved across from the ported file, and both are lunette's own: the first converts lunette's `PixelSize` newtype, and the second exists because a client is told which output it is on, which upstream never has to say.
- `src/state/pacing.rs` carries no header. The rate policy and the wakeup timer are new, and `send_frame_callbacks` is a rewrite around them rather than the drain WayVR performs. `CompositorState::millis` is the one thing here with an upstream counterpart, and it is not a port of it — see the `time.rs` paragraph above. The citation in the function is contrastive: lunette's clock is monotonic because WayVR's is not.

`MouseIndex` (`mod.rs:154`) is not ported. `protocol::PointerButton` covers it and covers the two side buttons WayVR omits.

`time.rs` is not ported either, though an earlier version of this file recorded it as folded into `CompositorState::millis`. The two answer the same question and share no code. WayVR reads `SystemTime::now().duration_since(UNIX_EPOCH)` and unwraps it, giving a `u64` of wall-clock milliseconds; `CompositorState::elapsed` reads `Instant::elapsed` from the moment the compositor started, and `protocol_millis` truncates to the `u32` the protocol carries. Wayland's timestamps must be monotonic and a wall clock is not, so the citation at `src/state/pacing.rs:135` states what WayVR does in order to say why lunette does something else. It is a contrast, not a derivation.

`image_importer.rs` is the exception to the rule that ported code lives here. Its dmabuf path is replaced by lunette's own `ash` import, and its `wl_shm` path lands in `crates/lunette`, because this crate must not gain a GPU dependency.

`input_capture.rs` is not ported. It grabs the host's own keyboard and pointer devices through libinput and evdev, which is host desktop integration rather than compositor work, and it belongs to no phase of v1.

Parts of the ported files are deliberately dropped rather than translated: the single-pixel-buffer handling and the fractional-scale calls in `comp.rs`, and the `wayvr_ipc` packet conversions in `window.rs`. Each drop is recorded as a comment at the site it would otherwise have occupied.

## House style

Vendored code is exempt from the house style in [CONTRIBUTING.md](../../CONTRIBUTING.md) until it is rewritten. Reformatting it wholesale destroys the ability to diff against upstream. Bring a file up to house style when a change touches it substantially, not in drive-by churn.

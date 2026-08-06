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
| `backend/wayvr/comp.rs`, `backend/wayvr/mod.rs` (the globals and output fragments) | `src/state.rs` |
| `backend/wayvr/mod.rs` (the surface-buffer fragments) | `src/surface.rs` |
| `backend/wayvr/window.rs`, `backend/wayvr/mod.rs` (the size-constraint fragment) | `src/window.rs` |
| `backend/wayvr/time.rs` | folded into `src/state.rs` as `CompositorState::millis` |
| `backend/wayvr/process.rs`, `backend/wayvr/mod.rs` (the spawn and attribution fragments) | `src/process.rs` |
| `backend/wayvr/client.rs`, `backend/wayvr/mod.rs` (`WaylandEnv`, `ExternalProcessRequest`) | `src/client.rs` |
| `backend/wayvr/hit_test.rs` | `src/hit_test.rs` |
| `backend/wayvr/image_importer.rs` | `crates/lunette/src/import/shm.rs` |

`mod.rs` is 1391 lines of which only fragments are wanted, so it lands in several files rather than one. Each names the fragments it took.

`src/protocol.rs`, `src/thread.rs`, `src/testing.rs`, and `src/test_client.rs` are lunette's own and carry no header. WayVR has no equivalent: its compositor runs on the caller's thread, driven per-tick from `mod.rs`, and it has no cross-thread protocol to define.

`MouseIndex` (`mod.rs:154`) is not ported. `protocol::PointerButton` covers it and covers the two side buttons WayVR omits.

`image_importer.rs` is the exception to the rule that ported code lives here. Its dmabuf path is replaced by lunette's own `ash` import, and its `wl_shm` path lands in `crates/lunette`, because this crate must not gain a GPU dependency.

`input_capture.rs` is not ported. It grabs the host's own keyboard and pointer devices through libinput and evdev, which is host desktop integration rather than compositor work, and it belongs to no phase of v1.

Parts of the ported files are deliberately dropped rather than translated: the single-pixel-buffer handling and the fractional-scale calls in `comp.rs`, and the `wayvr_ipc` packet conversions in `window.rs`. Each drop is recorded as a comment at the site it would otherwise have occupied.

## House style

Vendored code is exempt from the house style in [CONTRIBUTING.md](../../CONTRIBUTING.md) until it is rewritten. Reformatting it wholesale destroys the ability to diff against upstream. Bring a file up to house style when a change touches it substantially, not in drive-by churn.

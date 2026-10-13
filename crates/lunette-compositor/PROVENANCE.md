# Provenance

The compositor vendors WayVR's `wayvr/src/backend/wayvr/` at commit `42e9deb54cc5c36037b49237867afa3dc4593f4a` from <https://github.com/wayvr-org/wayvr>. The code is GPL-3.0-only, by galister and oo8dev. [Credits](../../CREDITS.md) records attribution; [Compositor](../../docs/development/native/compositor.md) records the integration constraints.

## Maintaining the vendor

`src/wayvr/` preserves upstream file names, identifiers, formatting, and attribution headers. It is excluded from rustfmt. Commit `fff5975` adds the upstream files verbatim; `git diff fff5975 -- crates/lunette-compositor/src/wayvr` shows lunette's changes. Compare an upstream fix against the recorded revision before applying it.

Every file in `src/wayvr/` names its upstream source and revision in a GPL-3.0-only attribution header. A file that takes fragments from several upstream files names each source. Lunette-authored files outside the directory do not carry that header.

## Relocated fragments

The upstream `client.rs`, `comp.rs`, `hit_test.rs`, `mod.rs`, `process.rs`, and `window.rs` retain their names under `src/wayvr/`. Fragments moved out of upstream files are recorded here because the directory alone cannot establish their origin:

| Upstream source | Destination |
|---|---|
| `mod.rs`: window size constraints | `src/window.rs` |
| `mod.rs`: seat construction | `src/seat.rs` |
| `mod.rs`: environment and authentication setup | `src/spawn/plan.rs` |
| `mod.rs`: process creation, adoption, and polling | `src/spawn/table.rs` |
| `mod.rs`: task drain | `src/commands/mod.rs` |
| `client.rs`: xwayland-satellite lifetime | `src/satellite.rs` |
| `image_importer.rs`: `wl_shm` repacking | `../lunette/src/import/shm.rs` |

GPU submission and buffer copies belong to the frame thread; this crate has no graphics dependency. Host input capture belongs to `lunette-capture`. Upstream overlay and IPC code is not ported. Git history records the implementation changes and removed symbols.

## Upstream defects lunette fixes

These fixes must survive an upstream refresh:

- Respect `wl_shm` pool offsets and bounds when copying a buffer.
- Read process environments as bytes, so non-UTF-8 values do not prevent attribution.
- Never signal a child after reaping it; its pid may have been reused.
- Apply buffer transforms before computing logical size, source crops, and viewport bounds.
- Use monotonic Wayland timestamps.
- Report popup configuration failures without panicking the compositor.
- Create the single-pixel-buffer global before handling that buffer type.

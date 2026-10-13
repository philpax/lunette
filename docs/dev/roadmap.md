# Roadmap

v1, the point at which the system is usable for daily work, is implemented. What remains is the work beyond v1.

## Non-routing audio

Non-routing audio provides owner-scoped system-mix and logical-process capture, reusable Lua analysis, a desktop backdrop, and an independent example consumer. [Audio](audio.md) specifies the contracts and pending live acceptance checks. `examples/audio-backdrop` demonstrates the backdrop and separate raw-PCM and feature consumption; `dev/plugins/audio-diagnostics` is an opt-in inspection plugin. These consumers do not redirect playback or change the default sink; spatial audio remains beyond v1.

## Beyond v1

Roughly WayVR's feature surface, plus what this architecture makes easier:

- Dashboard, launcher, notifications, settings, and taskbar, as example configurations rather than library code.
- [Per-application spatial audio](audio.md).
- Explicit sync (`linux-drm-syncobj-v1`) and the LÖVR external-semaphore patch.
- `ext-image-copy-capture-v1` in `wlx-capture`, contributed upstream.
- libei injection through the portal.
- Input blocking through libmonado ([Input](input.md#blocking-input-to-the-underlying-application)).
- IME integration, such as fcitx5.
- Extend the offscreen graphics tests beyond the aurora's raster and lifetime checks.

## Upstream work

- LÖVR: the patches marked upstreamable or as upstream defects in [the patch set](lovr-integration.md#the-patch-set).
- `wlx-capture`: selecting every monitor in one portal dialog and correlating the streams to outputs by logical geometry, and `ext-image-copy-capture-v1`.
- WayVR: whatever of the above applies to it.

## Decisions

Non-routing capture and reusable analysis precede spatial playback routing. Independent consumers need PCM without changing where applications are heard, while routing adds separate attribution, host-graph, and playback policy requirements. The roadmap therefore keeps spatial audio in the deferred work.

## Known gaps

The non-routing audio implementation has no recorded live PipeWire or headset acceptance. Automated contract, graph, analysis, and raster tests are insufficient to close that gap.

## Deliberately left open

The order of the beyond-v1 items, persistent source preferences, and additional backdrop effects remain open. Spatial playback routing is not implemented by the audio backdrop.

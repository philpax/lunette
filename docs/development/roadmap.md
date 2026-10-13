# Roadmap

## Deferred work

- [Spatial playback routing](native/audio.md#deferred-spatial-routing), separate from non-routing PCM capture.
- Explicit synchronization through `linux-drm-syncobj-v1` and LÖVR external-semaphore import.
- `ext-image-copy-capture-v1` in `wlx-capture` and libei input through the portal.
- [Input blocking](native/input.md#blocking-input-to-the-underlying-application) and IME integration.
- Additional desktop interfaces and broader offscreen rendering checks.

## Upstream work

The [LÖVR patch set](native/lovr-integration.md#the-patch-set) includes additive features and defect fixes to propose upstream. Capture fixes belong in `wlx-capture` in the WayVR monorepo. The order of deferred work is not fixed.

## Known gaps

Implementation does not establish daily-work acceptance. [Audio](native/audio.md#acceptance), [input](native/input.md#known-gaps), [host integration](native/host-desktop.md#known-gaps), and [rendering validation](native/rendering-validation.md) retain unresolved live checks and evidence limits.

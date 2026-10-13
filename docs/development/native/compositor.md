# Compositor

`lunette-compositor` serves Wayland clients on its own thread through bounded channels. It starts when LÖVR has a graphics device for buffer import. [Rendering](rendering.md#texture-import-and-lifetime) owns import lifetime; Lua owns spatial arrangement.

The crate hard-vendors WayVR's backend because that backend is coupled to WayVR's renderer and overlay loop rather than exposed as a library. Files under `src/wayvr/` retain upstream names, formatting, and headers so upstream fixes remain diffable. Additions belong beside that directory with minimal hooks inside it. [Provenance](../../../crates/lunette-compositor/PROVENANCE.md) owns the upstream record.

## Protocols

`Application::new` in `src/wayvr/mod.rs` owns the advertised globals. Viewports and fractional scale affect surface geometry; content-type hints reach Lua without native policy. Explicit synchronization is [unsupported](rendering.md#synchronisation).

## Outputs

Outputs are virtual monitors assigned per process before clients dispatch their first registry requests. Filtering gives a panel its own scale and refresh without exposing unrelated outputs. Live reassignment is unsupported because it requires withdrawing and recreating globals.

Unassigned and adopted clients receive the default output, which cannot be destroyed. Destroying another output returns its clients to the default. A scale change sends fractional scale, rounded buffer scale, and matching logical configure together. A partial update can produce sharp content at the wrong size. Refresh advertisement does not pace callbacks; [native pacing](rendering.md#frame-pacing-and-scene-skipping) does.

The output global is lunette-owned because smithay's private global data cannot support the required per-client filter. Readvertisement is non-atomic and currently relies on wayland-backend reusing the same global slot. Adding removable globals before the default output requires revisiting that assumption; a racing bind can otherwise reach the wrong replacement.

## Decorations

The compositor negotiates client- or server-side decorations but draws no chrome into client pixels. Lua supplies desktop decorations. A client with no request receives server-side mode.

## Windows

Surface size and pointer positions use logical surface coordinates, after buffer transform, scale, and viewport destination. Texture dimensions can differ. The snapshot reports source crop and child surfaces in bottom-first draw order relative to the window. Rendering and hit-testing must use the same geometry.

Native hit-testing resolves a pixel to a toplevel, subsurface, or popup and honors input regions and stacking. Popups can extend outside the window. Resize requests obey client limits and output bounds and remain pending until acknowledged by a commit.

Window bookkeeping runs after dispatch and before flushing clients. Handler-local registration would unnecessarily rewrite vendored handlers. Surface trees must refresh after dispatch even without a new buffer, because children can move or disappear independently.

## Drag and drop

A drag belongs to the seat whose press serial starts it. The handler records it immediately so icon commits in the same dispatch have an owner. Lua moves that seat pointer; [release delivery](input.md#drag-and-drop) preserves the original press sink while the current hover determines the drop target.

Closing the source window, destroying the source or seat, and source-reload handover cancel the drag. smithay has no cancellation operation: the compositor moves the pointer onto no target before releasing the grab, then restores hover. Releasing the grab while still over a target would drop rather than cancel. Only the icon's own surface is reported, not its subsurfaces.

## XWayland

The optional `xwayland-satellite` bridge maps X11 clients to Wayland; lunette has no X11 window-management implementation. A missing executable leaves X11 unavailable. Other spawn failures and bridge exit produce warnings. Compatibility is limited by satellite's xdg-shell translation.

## Processes

Spawned applications inherit the session's privileges. The compositor reaps owned children, captures output, and signals their process groups. `setsid` covers wrapper descendants, and parent-death signaling limits survival after a crash. There is no sandbox, cgroup, or systemd-scope integration. Restart, panel close, and last-window behavior are Lua policy.

### Attribution

Socket credentials and inherited random spawn tokens associate connecting clients with logical registrations and output assignments. Environment reads use bytes. Process identity must include the OS instance discriminator, not a reusable PID; [audio attribution](audio.md#process-attribution) adds checks for delayed external observations.

### Adoption

Clients launched outside lunette can connect to its logged Wayland socket and are adopted. Their liveness is observed, but lunette does not reap them. Disappearance removes the registration without an exit event because the exit status is unknown.

## Known gaps

Multi-seat toolkit behavior and drag ownership need live validation. Output readvertisement relies on the global-slot reuse noted above. X11 compatibility is delegated to satellite, and applications are not sandboxed.

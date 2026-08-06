# lunette v1 test requirements

This file maps every acceptance criterion in `docs/design-plans/2026-08-05-lunette-v1.md` to the thing that verifies it. It is derived from the eight phase plans in this directory: each criterion's row cites the phase and task whose Testing or Verification step describes the check, and nothing here claims coverage a phase file does not specify.

Verification runs in two tiers.

**Logic-headless automated tests.** Ordinary `cargo test` and pure-Lua tests, runnable with no GPU, no XR runtime, and no headset. Compositor tests connect a client over an in-process `UnixStream::pair()` rather than a bound socket, which is the default established by Phase 1 Task 10. The narrow exception recorded there covers the control socket's own listener tests, which bind in a per-test temporary directory because the listener is the thing under test.

**Human verification in a headset.** Everything that needs a physical display, an XR runtime, a GPU, a real portal, a host compositor, or a judgement about how something looks or feels. Each such criterion has a procedure below.

Of the 40 criteria, 14 are fully automated, 21 have automated coverage of their decidable parts plus a human gate for the observable outcome, and 5 are human-verified only.

## Automated tests

Paths are repository-relative and come from the Files sections of the cited tasks. Lua test paths are unspecified by the phase plans; see "Known limitations in verification".

| Criterion | What is verified | Type | Path | Owner |
|---|---|---|---|---|
| AC1.1 | A client connects over the harness socketpair and its toplevel appears in the snapshot on the tick after it maps | integration | `crates/lunette-compositor/tests/client_lifecycle.rs` | P2 T7, T15 |
| AC1.1 | A snapshot with two windows converts to two Lua entries with the expected fields | unit | `crates/lunette/src/lua/window.rs` | P2 T11 |
| AC1.1 | A window opening delivers `lunwindowopened`, and the window is present in the snapshot the handler reads | unit | `crates/lunette/src/events.rs` | P2 T12 |
| AC1.2 | The fourcc-to-Vulkan-format mapping, modifier filtering, disjoint-buffer detection, and the fd ownership state machine, as pure functions over plain data | unit | `crates/lunette/src/import/formats.rs`, `dmabuf.rs` | P2 T8 |
| AC1.2 | The frame-generation check on a returned texture handle | unit | `crates/lunette/src/texture.rs` | P2 T10 |
| AC1.3 | A connection whose auth key matches an unknown key is reported external, through the `ProcessSpawner` fake | unit | `crates/lunette-compositor/src/process.rs` | P2 T6 |
| AC1.4 | Spawning a non-existent executable produces a failure event and no window | unit | `crates/lunette-compositor/src/process.rs` | P2 T6 |
| AC1.4 | A failed spawn delivers `lunprocessexited` and creates no window | unit | `crates/lunette/src/events.rs` | P2 T12 |
| AC1.5 | A client disconnect produces `WindowClosed` and the handle goes dead | integration | `crates/lunette-compositor/tests/client_lifecycle.rs` | P2 T15 |
| AC1.5 | A dead handle's methods return `false` and do not raise; the handle is dead by the time the close handler runs | unit | `crates/lunette/src/texture.rs`, `src/lua/window.rs`, `src/events.rs` | P2 T10, T11, T12, T13 |
| AC1.6 | A `wl_shm` commit passes the validation path — stride and size bounds — to the extent testable without a GPU | integration | `crates/lunette-compositor/tests/client_lifecycle.rs` | P2 T15 |
| AC2.2 | Claims are granted in priority order, stably, and only at frame boundaries; a dead claim's methods return `false` without raising | unit | `crates/lunette/src/lua/claim.rs` | P3 T5 |
| AC2.2 | A layer texture handle used in a later frame raises rather than returning stale content | unit | `crates/lunette/src/layers/blit.rs` | P3 T8 |
| AC2.3 | A higher-priority claim arriving at capacity revokes the lowest; exactly one `lunlayerrevoked` and one `lunlayergranted` fire at the same boundary; an error in a handler prevents neither | unit | `crates/lunette/src/lua/claim.rs` | P3 T5, T6 |
| AC2.4 | A revoked layer returns to the free list and the next claim with an identical key allocates nothing; a different key allocates; the size ladder maps requested sizes onto the expected keys; the sweep destroys only past the threshold; the budget never exceeds the cap, counting stereo as two; creations never exceed the per-frame cap | unit | `crates/lunette/src/layers/pool.rs`, `key.rs` | P3 T2 |
| AC2.5 | An output is created with the requested dimensions; refresh converts to millihertz exactly once; two outputs with different scales coexist | unit | `crates/lunette-compositor/src/output.rs` | P8 T1 |
| AC2.5 | A client assigned one output sees exactly that one in the registry; a client assigned none sees none; a bind for an unassigned output fails; reassignment removes and recreates | integration | `crates/lunette-compositor/src/output.rs`, `src/state.rs` | P8 T2 |
| AC2.5 | The preferred scale is sent as `round(scale * 120)`; an unchanged value sends nothing; a value set before the object exists is replayed on creation; `wl_output.scale` and the toplevel configure accompany the change | integration | `crates/lunette-compositor/src/state.rs` | P8 T3 |
| AC2.5 | A distance maps to the expected ladder step; a threshold does not change step until crossed; crossing back requires the lower threshold; emitted sizes are all on the ladder; extremes clamp | unit (Lua) | `lua/mullion/scale.lua` | P8 T4 |
| AC3.1 | A full channel drops the oldest frame and increments the counter; a dmabuf frame converts to the import path's input type with planes intact; an `Implicit` frame is rejected with a clear error | unit | `crates/lunette-capture/src/stream.rs` | P4 T5 |
| AC3.2 | A hit at a panel's centre maps to the centre of the target monitor; a scaled monitor maps by logical size; a non-zero origin offsets correctly; a rotated monitor maps through the transform; clamping keeps a near-edge hit inside the monitor; recomputation after a simulated hotplug produces the new mapping | unit | `crates/lunette-capture/src/hid/mapping.rs` | P4 T7 |
| AC3.2, AC3.3 | A pointer to a host sink reaches the provider and not the compositor, and the converse for a window sink; two sinks in different domains route independently in one frame; Lua can read the domain | unit | `crates/lunette-compositor/src/protocol.rs`, `crates/lunette/src/lua/sink.rs` | P4 T9 |
| AC3.3 | Provider selection given a set of probe results: uinput wins when available, `wl_virtual` when the wlr protocols are present, the dummy otherwise with an error naming both failures; the config override wins | unit | `crates/lunette-capture/src/hid/mod.rs` | P4 T6 |
| AC3.4 | Connector match beats descriptor match; case-insensitivity in both; a UUID-shaped `mapping_id` is rejected; two identical descriptors demote the second; the saved key prefers the descriptor; a degraded key upgrades on reattach; sort order is independent of insertion order | unit | `crates/lunette-capture/src/monitor/name.rs` | P4 T2 |
| AC3.4 | Against the portal fake: the new token replaces the old after each `Start`; a downgraded `persist_mode` is stored as granted; streams correlate to the right monitors in any order; an unmatched stream is reported rather than dropped | unit | `crates/lunette-capture/src/portal.rs`, `tokens.rs` | P4 T4 |
| AC3.5 | Against the portal fake: mirroring requests a session once; dismissing stops the stream and retains the session; re-adding restarts without a new request; a revoked session falls back to a fresh request; dismissing twice is idempotent | unit | `crates/lunette-capture/src/stream.rs`, `src/portal.rs` | P4 T8 |
| AC4.1 | Two seats over the socketpair harness each hover a different window with their own pointer position; focus on one does not disturb the other; a modifier held on one does not appear on the other; removing a seat leaves the other functional | integration | `crates/lunette-compositor/src/seat.rs` | P5 T1 |
| AC4.2 | A keycode with a modifier produces the character the layout defines; reverse lookup round-trips for every keysym the layout expresses; an inexpressible keysym is absent rather than mapped wrongly; modifier state updates are visible to a client | unit | `crates/lunette-compositor/src/keymap.rs` | P5 T3 |
| AC4.2 | The layout list is readable from Lua; forward lookup matches the keymap; reverse lookup returns keycode and modifier pairs Lua can feed back into `sink:key` | unit | `crates/lunette/src/lua/sink.rs` | P5 T4 |
| AC4.3 | Text the layout expresses uploads no keymap; text it cannot triggers exactly one upload and one restore; oversized text produces the expected number of chunks; a simulated mid-chunk failure still restores; the emitted key sequence matches the text | unit | `crates/lunette-compositor/src/type_text.rs` | P5 T5 |
| AC4.3 | End to end over the socketpair harness: a test client receives the expected characters, and its keymap after typing equals its keymap before | integration | `crates/lunette-compositor/src/type_text.rs` | P5 T5 |
| AC4.4 | A click inside a popup overlapping the toplevel goes to the popup in surface-local coordinates; a click outside every popup goes to the toplevel; a subsurface offset by `SubsurfaceCachedState.location` receives translated coordinates; an empty input region is skipped; a buffer-less surface with an explicit input region still receives; an unconfigured popup is ignored; overlapping surfaces resolve top-most-first | unit | `crates/lunette-compositor/src/hit_test.rs` | P5 T2 |
| AC4.5 | A client setting a selection produces an offer to the host; a host selection is offered to clients; primary works in both directions independently of the regular selection; an unrepresentable MIME type fails rather than substituting; the transfer queue bounds concurrency; a client disconnecting mid-transfer leaks no worker | unit, integration | `crates/lunette-compositor/src/selection/mod.rs`, `host.rs` | P5 T6 |
| AC4.5 | The bridge seat receives host selections and pushes its own; a non-bridge seat does neither; reassigning the bridge seat moves both behaviours at a frame boundary; two seats holding different selections do not interfere | unit | `crates/lunette-compositor/src/selection/mod.rs` | P5 T7 |
| AC5.1 | Ray-quad intersection: a ray through the centre hits the centre pixel; a corner ray hits the corner pixel; a miss and a parallel ray return nothing; a rotated and translated panel maps correctly; a non-square panel maps both axes independently | unit (Lua) | `lua/mullion/panel.lua` | P6 T5 |
| AC5.1 | Against a fake `lunette` API: a granted claim drives the layer path; a revocation switches to the quad path without losing the panel; a dead source removes the panel | unit (Lua) | `lua/mullion/panel.lua` | P6 T5 |
| AC5.2 | A rule matching `appId` applies its properties; a non-matching rule does not; two matching rules layer in order; a function-valued property is evaluated at application time; an empty table is a no-op; a rule matching on an absent field does not match rather than erroring | unit (Lua) | `lua/mullion/rules.lua` | P6 T9 |
| AC5.3 | A saved arrangement round-trips; a stale entry is skipped and reported while the rest restores; an absent save file yields defaults; an older-version save loads or is rejected explicitly rather than partially applied; restore and rules compose in the declared precedence | unit (Lua), round-trip property | `lua/mullion/persist.lua` | P6 T10 |
| AC5.3 | n panels in an arc are equidistant and evenly spaced; one panel sits at the midpoint; zero panels is a no-op; multi-tag membership does not duplicate a panel; an unselected tag does not participate | unit (Lua) | `lua/mullion/tag.lua`, `lua/mullion/layout/arc.lua` | P6 T8 |
| AC5.4 | Teardown hooks run before clearing; `lovr.*` is never cleared and user namespaces are; a deleted callback stops being called; a failing `main.lua` leaves the previous session running and reports; no client disconnects; timers and signal connections do not accumulate across ten reloads | unit | `crates/lunette/src/reload.rs` | P7 T1 |
| AC5.4 | Headless with a fake `lunette` API: a hand-placed panel returns to its stored pose; a window with no stored state is placed by rule; a window closed during the reload is not resurrected; a window opened during it is picked up | unit (Lua) | `lua/mullion/persist.lua`, `lua/mullion/panel.lua` | P7 T2 |
| AC5.4 | A value set before a simulated Lua-state teardown is readable after; a table is rejected with an error naming the key; entries drop when the window closes; `WindowId` is stable across a reload; an absent key returns nil | unit | `crates/lunette/src/properties.rs` | P6 T1 |
| AC5.4 | Each mullion module requires twice without duplicating signal connections, teardown hooks, or timers; hooks run in reverse registration order and one raising does not prevent the rest | unit (Lua) | `lua/mullion/teardown.lua`, `lua/mullion/signal.lua` | P6 T3, T4, T13 |
| AC5.5 | Against a fake compositor thread: quiesce releases every tracked GPU object; the main thread blocks until acknowledged; the dmabufs are retained; the Wayland socket and client connections are untouched; an empty quiesce completes immediately; a thread failing to acknowledge within a bound is reported rather than deadlocking | unit | `crates/lunette/src/restart.rs`, `crates/lunette-compositor/src/thread.rs` | P7 T3 |
| AC5.5 | After quiesce and republish, every retained dmabuf re-imports; the import cache is rebuilt; clients remain connected; a failed re-import is reported without failing the restart; the layer pool re-grants from empty | unit | `crates/lunette/src/restart.rs`, `src/boot.rs` | P7 T4 |
| AC7.1 | Snapshot generation increases monotonically; a command sent while the channel is full applies backpressure rather than being dropped — no socket, no client, no GPU | unit | `crates/lunette-compositor/src/protocol.rs`, `src/thread.rs` | P2 T4 |
| AC7.2 | Synthetic `CommitCounter` sequences against a fake blitter: an unchanged counter produces no blit; a moved counter produces one; a jump beyond `MAX_DAMAGE_AGE` produces a full blit; a reset produces a full blit; a skipped frame still submits the layer | unit | `crates/lunette/src/layers/blit.rs`, `crates/lunette-compositor/src/state.rs` | P3 T7 |
| AC7.2 | A stale claim is not blitted but is still submitted; a claim whose source commits is blitted | unit | `crates/lunette/src/layers/blit.rs` | P8 T7 |
| AC7.3 | Pure over a fake clock, no sleeps: a surface at 10 Hz receives a callback roughly every 100 ms of virtual time; at the floor it still receives one per second; callbacks withheld across several commits are all delivered on the next send; a rate change takes effect at the next interval; a surface with no rate set is unthrottled | unit | `crates/lunette-compositor/src/pacing.rs` | P8 T5 |
| AC7.3 | A surface setting `Video` reports it to Lua; a surface setting nothing reports `None`; the value is double-buffered and takes effect at commit | unit | `crates/lunette-compositor/src/state.rs` | P8 T6 |
| AC7.4 | A frame with only layers and no draw calls does not call `getPass` and sets `main = false`; a frame with in-scene content does both; the XR frame is submitted in both cases; the transition between the two does not drop a frame | unit | `crates/lunette/src/boot.rs`, `src/layers/mod.rs` | P8 T8 |
| AC8.1 | A nested table round-trips; a cycle produces the documented behaviour; a shared subtable preserves or does not preserve identity as documented; a function value errors naming its path; a handle round-trips to the same object; a dead handle's id deserialises to something inert; depth and node caps produce clean errors; mixed array and hash parts survive | unit, round-trip property | `crates/lunette/src/control/serialise.rs` | P7 T7 |
| AC8.1 | `lunctl` spawns a client, asserts it appears in `lunette.windows()`, asserts its properties, and tears down, using a unique identifier per run | e2e shell | `tests/e2e/lunctl.sh` | P7 T11 |
| AC8.2 | The directory is created 0700 and the socket 0600; binding twice reports rather than stealing; a stale socket with no listener is replaced and one with a live listener is not; the disable switch prevents creation entirely; a full channel applies backpressure | unit (binds in a per-test temporary directory, the Phase 1 Task 10 carve-out) | `crates/lunette/src/control/socket.rs` | P7 T5 |
| AC8.2 | A chunk returning multiple values returns all; a load error is distinguishable from a runtime error; a chunk exceeding the budget is abandoned and reported; a chunk catching the abort with `pcall` escapes the budget, asserted as documented behaviour; evaluation never overlaps a frame callback | unit | `crates/lunette/src/control/eval.rs` | P7 T6 |
| AC8.3 | An error in a callback is caught with a traceback and the session continues; `lovr.lunerror` is delivered with a table payload; a name at the length limit round-trips and one over it is rejected at build time; a callback erroring every frame does not prevent later frames | unit | `crates/lunette/src/lua/mod.rs`, `src/events.rs` | P7 T9 |
| AC8.3 | Identical errors are rate-limited and report a count; distinct errors are not conflated | unit (Lua) | `lua/mullion/error.lua` | P6 T4 |
| AC8.4 | A syntactically invalid `main.lua` produces safe mode; a missing `main.lua` produces safe mode; the load error is available to it; safe mode runs with the standard library entirely absent; a runtime error after a successful load does not produce safe mode | unit | `crates/lunette/src/boot.rs` | P7 T10 |
| AC9.2 | `cargo +nightly fmt --all -- --check` and both clippy invocations from `CONTRIBUTING.md`, plus `cargo test --workspace` with and without default features, run inside `nix develop` | e2e shell | the five commands at `CONTRIBUTING.md:171-175` | P1 T11, and the check-suite task of every later phase |
| AC9.3 | `rg -L 'Ported from WayVR' crates/lunette-compositor/src/` returns no output, meaning every file in the crate is either ported and headed or original | e2e shell | `crates/lunette-compositor/`, `CREDITS.md`, `crates/lunette-compositor/PROVENANCE.md` | P2 T1, T16 |
| AC9.4 | `cargo test -p lunette-compositor` passes with no Vulkan ICD visible, and `cargo tree -p lunette-compositor` shows no `lunette-lovr` and no GPU crate | e2e shell | `crates/lunette-compositor/` | P2 T15, P5 T8, P8 T9 |

## Human verification

Each entry states why the criterion resists automation and gives a procedure. Run every headset procedure under Monado in service mode: overlay sessions do not work in monolithic mode, because `multi_compositor_create` never initialises `z_order` from the session create-info and only the IPC server calls `set_z_order`.

### AC1.2 — a committed dmabuf imports, and the texture matches the surface

Automated coverage stops at the pure functions. The Vulkan calls need a real device and a real client buffer, so the import itself cannot be unit-tested. Phase 2 Task 8 says so directly.

1. Start lunette in the desktop simulator on a Mesa system.
2. Spawn a terminal with `lunette.spawn`.
3. From `lunctl`, evaluate a chunk reading `w.width`, `w.height`, and the dimensions of `w:getTexture()` for that window.
4. Pass: the texture's dimensions equal the surface's, and the terminal's content is visible on the quad rather than black, garbled, or a single flat colour.
5. Record in `docs/milestone-0-findings.md` whether the `UNDEFINED` transition discarded content on this driver, whether `VK_QUEUE_FAMILY_FOREIGN_EXT` or `VK_QUEUE_FAMILY_IGNORED` worked, and which formats and modifiers the hardware advertised.

### AC1.6 — a `wl_shm` client produces a usable texture

The validation path is tested headlessly; producing an actual texture from the memcpy path needs a GPU.

1. Run a client known to use `wl_shm` rather than dmabuf — `weston-simple-shm` or an application launched with dmabuf disabled.
2. Draw its texture on a quad.
3. Pass: the content appears correctly, with no stride-padding artefacts down the right edge and no colour-channel swap.

### AC2.1 — a window texture on an in-scene quad appears at the specified pose

Needs a rendered scene. Phase 2 Task 14 records it as human-verified.

1. Set a known pose in `etc/xdg/lunette/main.lua` — for example one metre forward and level with the head.
2. Start lunette and spawn a terminal.
3. Pass: the quad appears at that pose, with the terminal legible and the right way up, and it does not move with the head.

### AC2.2 — a layer renders at native resolution and is visibly sharper

This is a judgement about image quality, made through a headset lens. Phase 3 Task 9 records it as the phase's human gate.

1. Start lunette under Monado in service mode with a headset attached.
2. Open a text-heavy terminal — a manual page or a source file fills the screen with small glyphs.
3. Show the same panel in-scene, at a comfortable reading distance.
4. Claim a layer for it and let the grant land.
5. Pass: the text is visibly sharper on the layer, with less shimmer on the glyph edges when the head moves slightly. Toggle back and forth to compare rather than judging one state alone.
6. Record the `maxLayerCount` Monado reported, the cap chosen against it, the free-list hit rate in ordinary use, whether format conversion was needed, and whether a `lovrLayerCreate` stall was ever observed.

### AC2.5 — raising output scale makes the client re-render sharper

Whether a client honours `wp_fractional_scale_v1` is a property of the client, and the resulting sharpness is a visual judgement.

1. Place a panel at a distance that puts it on the low end of the scale ladder.
2. Confirm the client's view of its outputs with `wayland-info` run inside the client's environment: it must list exactly the output it was assigned and no others.
3. Walk toward the panel until the ladder crosses a step.
4. Pass: the client re-renders, the panel's content becomes sharper rather than merely larger, and the layer samples the new buffer instead of scaling the old one.
5. Record which clients honoured the protocol and which ignored it, and whether the ladder's steps were the right ones.

### AC3.1 — a mirrored monitor appears with a matching texture

Needs a real portal, a PipeWire session, and a GPU.

1. Start lunette on a host session with a working `xdg-desktop-portal` ScreenCast backend.
2. Mirror a monitor from Lua.
3. Approve the portal dialog.
4. Pass: the panel shows live host content, and the texture's dimensions match the captured output's pixel resolution.

### AC3.2 — pointer coordinates move the host cursor to the right place

Needs uinput or `wl_virtual` permissions and a physical display to observe.

1. Mirror a monitor and point a laser at the centre of its panel.
2. Pass: the host cursor sits at the centre of that physical display.
3. Repeat on a monitor with a fractional scale factor set. Pass: the cursor still lands at the centre, not offset by the scale ratio.
4. Repeat on a monitor whose logical origin is not `(0, 0)` — a second screen to the right of the primary. Pass: the cursor lands on that screen, not the primary.
5. Point near the panel's edge on a non-rectangular arrangement. Pass: the cursor clamps to the monitor's rectangle rather than landing in a gap between screens.
6. Run the whole procedure under GNOME as well as under a wlroots compositor, and record the result. See "Known limitations".

### AC3.3 — keystrokes reach whatever the host focuses

1. Focus a text editor on the host desktop, outside lunette.
2. From inside lunette, point at that monitor's panel and type.
3. Pass: the characters appear in the host editor.
4. Change the host's focused window without touching lunette, and type again. Pass: the characters go to the newly focused window; lunette does not choose the target.

### AC3.4 — monitors identify themselves without a prescribed order

The mechanism was restated during planning; see "Known limitations". The outcome is what is verified.

1. Delete any stored restore tokens and start lunette.
2. Mirror all monitors. Pass: one portal dialog appears, and screens can be selected in any order.
3. Confirm each panel is bound to the monitor it depicts.
4. Restart lunette. Pass: each monitor reattaches to the same panel, without a per-screen selection ritual.
5. Physically move one monitor to a different port and restart. Pass: identity follows the monitor, not the connector, where a descriptor is available.
6. Record which portal backend was tested, what it put in `mapping_id`, and whether restore actually skipped the prompt on the second run.

### AC3.5 — dismissing a mirror stops its capture

1. Mirror a monitor and confirm the panel is live.
2. Dismiss it from Lua.
3. Pass: the host's screen-share indicator clears, or `pw-top` shows the stream gone, and lunette's CPU use drops.
4. Re-add the monitor. Pass: capture restarts, and no portal dialog appears because the session was retained.

### AC4.1 — two seats hover two windows simultaneously

Needs two tracked controllers.

1. Start lunette with two windows placed side by side and a laser per hand.
2. Point the left hand at one window and the right hand at the other, at the same time.
3. Pass: both windows show a cursor, each at the position its own laser indicates, and moving one hand does not move the other's cursor.
4. Click with one hand. Pass: focus follows that hand's seat only; the other window keeps its own hover state.

### AC4.2 — typing produces the layout's characters

1. Focus a terminal panel and type a phrase using a non-US layout, including at least one character that requires a modifier.
2. Pass: the characters that appear are the ones the active layout defines for those keycodes.

### AC4.3 — `typeText` enters text the layout cannot express

1. With a US layout active, call `sink:typeText` with text containing characters the layout cannot produce — accented letters, or an emoji.
2. Pass: the full text appears in the client.
3. Immediately type on the physical or virtual keyboard afterwards. Pass: the client's own keymap handling is intact and the ordinary characters are correct, meaning the temporary keymap was restored.

### AC4.4 — a click on a popup goes to the popup

Automated over synthetic surface trees; confirmed once against a real toolkit.

1. Open an application with a dropdown menu that extends beyond its toplevel.
2. Open the menu and click an item in the part that overhangs the window.
3. Pass: the menu item activates, rather than the click landing on whatever is behind it in the toplevel.

### AC4.5 — clipboard bridges both ways, for both selections

Needs a real host compositor with a clipboard.

1. Copy text in a host application.
2. Paste into a lunette terminal. Pass: the text arrives.
3. Copy text in the lunette terminal and paste into a host application. Pass: the text arrives.
4. Select text with the mouse in a host application without copying, then middle-click into a lunette terminal. Pass: the primary selection arrives.
5. Select text in a lunette client and middle-click into a host application. Pass: the primary selection arrives.

### AC5.1 — a `mullion` panel appears at the configured pose and size

The geometry is tested; whether it is where the configuration meant is a headset check.

1. Start with the shipped default configuration.
2. Pass: it spawns a terminal onto a panel, at the pose and metre size the configuration states — check the size against a known reference such as arm's length.
3. Grab the panel and move it. Pass: it moves with the hand and stays where it is released, and the movement feels attached rather than lagging or overshooting. This tuning judgement is the phase's stated human gate.

### AC5.3 — a saved arrangement is restored after a restart

The serialisation round-trips headlessly; restoring against real windows and monitors does not.

1. Arrange several panels by hand, across at least two tags.
2. Quit lunette.
3. Start it again with the same applications available.
4. Pass: the panels return to their saved poses, sizes, and tag membership.
5. Unplug a mirrored monitor and repeat. Pass: the rest of the arrangement restores, and the missing entry is reported rather than failing the whole restore.

### AC5.4 — reload applies a layout change without disconnecting clients

1. Start lunette and spawn two clients. Note their pids.
2. Move one panel by hand.
3. Edit `main.lua` to change the layout.
4. Call `lunette.reload()` from the in-headset binding or from `lunctl`.
5. Pass: the new layout applies, both pids are still running, no client redrew from scratch, and the hand-placed panel keeps its pose.
6. Reload ten times in succession. Pass: nothing accumulates — one laser per hand, no duplicated signal handlers, no growing frame time.

### AC5.5 — restart rebuilds the Lua state and the XR session

1. With two clients connected, call `lunette.restart()`.
2. Pass: a visible hitch and brief blackness, then the session returns with both clients still connected and rendering.
3. Check the log for Vulkan validation errors at teardown. A validation error means the quiesce missed a GPU object, and the criterion fails even if the session appears to recover.
4. Record whether the quiesce covered every GPU object, whether re-import succeeded for every retained dmabuf, whether any client noticed, and how long the restart took end to end.

### AC6.1 — lunette runs as an overlay under Monado

Needs an XR runtime, a headset, and a second OpenXR application. There is no substitute.

1. Start Monado in service mode.
2. Start another OpenXR application and let it take the primary session.
3. Start lunette.
4. Pass: lunette creates its session and runs alongside the other application, rather than failing session creation or displacing it.

### AC6.2 — layers composite over the underlying application

1. With the setup from AC6.1 running, look at a region where lunette draws a panel.
2. Pass: the panel appears over the other application's view.
3. Look at a region where Lua drew nothing.
4. Pass: the other application is fully visible there, with no grey, black, or tinted overlay film.

### AC7.1 — a stalled client does not extend lunette's frame time

The channel and snapshot protocol are unit-tested; the frame-time property itself is measured against a real client.

1. Start lunette with a client whose dispatch can be paused — attach a debugger and stop it, or send `SIGSTOP`.
2. Record lunette's frame time before stopping the client.
3. Stop the client.
4. Pass: lunette's frame time is unchanged, the panel holds its last content rather than blocking the frame, and interaction with other panels stays responsive.

### AC7.3 — a throttled panel stays responsive

The pacing logic is tested over a fake clock. That the client keeps processing input is a property of the real client.

1. Place a panel behind the head, or otherwise outside the view, so Lua throttles it toward the floor.
2. Confirm its redraw rate has dropped — a clock or a scrolling log in the client makes this visible.
3. While it is throttled, click it and type into it.
4. Pass: it reacts. A client that ignores input while throttled fails the criterion even though the rate dropped correctly, and that is the half a zero rate would fail.

### AC7.4 — the projection layer is skipped when Lua draws nothing

Whether the render pass is genuinely skipped cannot be read from frame rate.

1. Reach the steady state the criterion names: every panel on a layer, nothing drawn in-scene.
2. Attach a GPU profiler, or read LÖVR's own timing.
3. Pass: no render pass is issued for the frame, and no colour swapchain image is acquired. Inferring it from a frame-rate improvement is not sufficient.
4. Draw one in-scene quad. Pass: the render pass reappears, and the transition drops no frame.
5. Record the measured cost of an idle frame with scene rendering skipped.

### AC8.3 — a callback error shows a panel and the session continues

The native catching is unit-tested; the panel is a rendered artefact.

1. Edit a callback in `main.lua` to raise an error every frame.
2. Reload.
3. Pass: an error panel appears with the message and a traceback, and the session keeps rendering rather than freezing or exiting.
4. Watch the panel over several seconds. Pass: the repeated identical error is rate-limited and reports a count, rather than one panel per frame.

### AC8.4 — an invalid `main.lua` produces safe mode

1. Introduce a syntax error into `main.lua`.
2. Start lunette with a headset attached.
3. Pass: safe mode appears with a laser, a panel showing the load error, and a working reload key — not a black headset.
4. Fix the file and press the reload key. Pass: the ordinary session starts.
5. Repeat with the standard library absent entirely — unset `LUNETTE_STDLIB_PATH` and point it at an empty directory. Pass: safe mode still works, since it must not `require 'mullion'`.

### AC9.1 — a clean recursive clone builds offline

Not headset work, but it cannot be checked from inside the working tree, and no CI job for it is specified in the phase plans.

1. `git clone --recursive <repo> /tmp/lunette-clean-clone`
2. `cd /tmp/lunette-clean-clone`
3. `nix develop --command cargo build`, with networking disabled if the environment permits.
4. Pass: the build succeeds, and the cmake step makes no network access — the prefetched JoltPhysics source is reached through `FETCHCONTENT_SOURCE_DIR_JOLTPHYSICS`.
5. Remove the clone.

## Environment requirements

Set these up once. The automated tier needs none of them.

**XR hardware and runtime.** A headset, and Monado running in service mode. Monolithic mode does not support overlay sessions, so every overlay and layer check fails misleadingly there. A second OpenXR application is needed to hold the primary session for AC6.1 and AC6.2, and it must be one that keeps running while lunette starts and stops. LÖVR's desktop simulator substitutes for the headset only where a procedure says so.

**GPU and drivers.** A Mesa system for the dmabuf import path. The design assumes implicit sync works there, on the strength of WayVR's experience, and milestone 0 exists partly to confirm it. A GPU profiler, or LÖVR's own timing, is needed for AC7.4.

**Host desktop.** A Wayland host compositor with a working `xdg-desktop-portal` ScreenCast backend at version 5 or later, plus PipeWire. Test on a wlroots-based compositor and on GNOME, because the portal backends differ in what they report and the input-injection story differs too. A multi-monitor arrangement is needed for AC3.2 and AC3.4: at least one monitor with a fractional scale factor, one at a non-zero logical origin, and ideally a non-rectangular arrangement to exercise clamping.

**Input injection.** Membership of the `input` group and a loaded `uinput` module, or `zwlr_virtual_pointer_v1` and `zwp_virtual_keyboard_v1` on a wlroots host. The group grants read access to all input devices, which is a deliberate choice the tester makes knowingly. Neither is available on GNOME in a usable form; see below.

**Clients.** A text-heavy terminal for AC2.2. A `wl_shm`-only client for AC1.6. An application with an overhanging dropdown menu for AC4.4. A client that honours `wp_fractional_scale_v1` for AC2.5, and ideally one that does not, to see both paths.

**Build environment.** Nix with flakes, a nightly Rust toolchain for the fmt check, and a network-disabled shell for AC9.1.

## Known limitations in verification

**Three criteria were restated during planning.** Each stated a mechanism that investigation showed to be impossible or non-portable. The outcome each asked for is unchanged and is what the procedures above verify.

- **AC2.4** named swapchain recycling keyed on width, height, and format. LÖVR's `struct Layer` embeds its swapchain by value and `lovrLayerDestroy` calls `xrDestroySwapchain` inline, with no way to detach one from the other. The recycling unit is the whole `Layer`. Format is not an axis at all: `lovrSwapchainInit` hard-codes `VK_FORMAT_R8G8B8A8_SRGB` and session start aborts if the runtime refuses it. Phase 3 Task 3 restates the criterion and records the decision.
- **AC3.4** named the portal's `mapping_id` as the identity mechanism. It yields a connector name on xdg-desktop-portal-wlr, a random UUID on mutter and only under a RemoteDesktop session, and nothing on KDE. Identity comes from a niri-style matcher over connector, make, and model, correlated to streams by logical geometry. Phase 4 Task 3 restates the criterion. The ceiling is that serial is unavailable to a Wayland client, so two identical monitors of the same model are indistinguishable and fall back to positional identity, which does not survive rearrangement.
- **AC8.2's first clause** asked for a wall-clock budget on `lunctl` chunks. Under LuaJIT the budget is advisory: JIT-compiled code does not call debug hooks (mitigated with `jit.off`), an `error()` from a hook can be caught by a `pcall` inside the user's own chunk, and a loop inside a C function or a blocking FFI call is uninterruptible. A hard bound would need a watchdog that could only abort the process, taking every connected client with it. Phase 7 Task 6 restates the clause as best-effort. The test asserts the documented escape rather than an aspiration.

**Partially verifiable criteria.** AC1.2 and AC1.6 have automated coverage of their pure logic only; the Vulkan and memcpy paths need a device. AC7.1's protocol is tested but its frame-time property is observed, not measured automatically. AC2.5, AC3.1 through AC3.5, AC4.1 through AC4.3, AC4.5, AC5.1, AC5.3 through AC5.5, AC7.3, AC7.4, AC8.3, and AC8.4 each have logic tests plus a human gate for the observable outcome.

**Open questions milestone 0 exists to answer.** Phase 2 records three Vulkan unknowns and Phase 2 Task 16 requires the answers be written to `docs/milestone-0-findings.md`. Whether the `UNDEFINED` transition at `gpu_vk.c:3789` actually discards a client's content on the target driver, and so whether the `foreign` flag is necessary or merely prudent. Whether `VK_QUEUE_FAMILY_FOREIGN_EXT` or `VK_QUEUE_FAMILY_IGNORED` works for the import acquire, and whether behaviour differs by driver — Phase 2 Task 10 makes this a runtime switch precisely because the answer is unknown. Whether implicit sync suffices in practice. Until these are answered, AC1.2's automated coverage cannot be extended and the driver-dependence of the import path is untested outside Mesa.

**Driver- and compositor-dependent results.** Whether mutter maps a bare `ABS_X`/`ABS_Y` uinput device across the whole layout or binds it to a single monitor is unverified, and Phase 4 Task 7 records it as a known unknown to be settled during Task 10. If it binds to one monitor, AC3.2 cannot pass on GNOME with either provider, because `wl_virtual` is unavailable there too — KWin and mutter do not implement it and have no plans to. The honest answer for GNOME is the libei path, which v1 does not implement. Portal behaviour also varies: restore tokens are single-use, a rejected token produces no error but a dialog, and backends may downgrade the granted `persist_mode`, so "no prompt on the second run" is a likely outcome rather than a guaranteed one. Monado does not bounds-check `layerCount`, so the layer budget is a conservative cap rather than a runtime-enforced limit, and under `XR_EXTX_overlay` the array is shared with a primary application whose layer count lunette cannot observe.

**Coverage gaps in the plans themselves.** The Lua test paths in the table above name the module under test rather than a test file. The harness is settled — Phase 6 Task 3 Step 6 establishes it: specs live in `lua/spec/`, mirroring the module tree, run by a plain LuaJIT runner with an explicitly constructed fake of the `lunette` API, invoked from Task 13's check step. So a spec for `lua/mullion/signal.lua` is `lua/spec/mullion/signal_spec.lua`, and the paths below can be derived mechanically. Phase 2 Task 9's `wl_shm` fallback specifies no test step of its own; its coverage comes from Task 15's validation-path test and the AC1.6 human procedure. AC9.3's automated part is a ripgrep over provenance headers; that `vendor/lovr` patches carry MIT headers and that `CREDITS.md` agrees with the licensing table in `docs/decisions.md` is checked by reading, not by a script.

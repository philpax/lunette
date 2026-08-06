# lunette v1 Implementation Plan — Phase 6: The mullion standard library

**Goal:** Panels, interaction, and layout usable from a configuration file.

**Architecture:** `mullion` is Lua, installed to `$PREFIX/share/lunette/lua/`, written against the same public `lunette` API a downstream user has. One native task supports it: a per-window property store, because the Lua state is discarded on reload and mullion needs somewhere for state that no rule can derive. Everything else is policy in Lua — signals, panels, lasers, tags, rules, and persistence.

**Tech Stack:** LuaJIT (Lua 5.1 syntax), LÖVR's `Pass` and `lovr.headset` APIs, `lovr.filesystem` for persistence.

**Scope:** Phase 6 of 8. `docs/stdlib.md` is deliberately provisional, so this phase implements each tier's minimum-viable line rather than its full description. See the scope note below.

**Codebase verified:** 2026-08-06.

---

## Acceptance criteria coverage

### lunette-v1.AC5: Arrangement is scripted, and iteration is fast
- **lunette-v1.AC5.1 Success:** A panel created through `mullion` appears at the pose and metre size the configuration specifies.
- **lunette-v1.AC5.2 Success:** A rule matching on `appId` places a newly spawned window without further scripting.
- **lunette-v1.AC5.3 Success:** A saved arrangement is restored after a restart.

---

## Scope: the minimum-viable lines are the contract

`docs/stdlib.md:5` disclaims its own tier descriptions:

> Nothing here is settled… What follows describes the intended tiers and the minimum viable version of each, not a committed API surface. Concrete signatures land once the thing has been used.

Each tier therefore has a broad description and a narrower minimum-viable line, and the narrow line is what this phase builds.

- **Tier 1** (`:11`): create a panel from a window or a monitor, place it with a `mat4`, draw it in-scene, raycast a quad, feed the sink.
- **Tier 2** (`:21`): one laser per hand, hover highlight, trigger-to-click, grab-to-move, keyboard typing into the focused sink.
- **Tier 3** (`:29`): one layout function arranging the current tag's panels in an arc at a comfortable radius, a rules table matched on `appId`, and layout save/restore to `lovr.filesystem`'s save directory.
- **Tier 4** (`:39`): the default config spawns a terminal, shows it on a panel, and provides a laser and a reload key. Nothing more.

Two consequences, both decided on 2026-08-06:

**Grab-to-resize is deferred.** It appears in tier 2's description (`:17`) and in the design plan's Phase 6, but not in the minimum-viable line at `:21`. `stdlib.md:19` says this tier is tuning-heavy and that feel accounts for most of the work, so resize lands once move has been tuned in a headset.

That deferral contradicts the design plan, which lists grab-to-resize in Phase 6's components (line 311) and requires "panels can be grabbed and resized" in its "Done when" (line 317). **Task 6 amends the design plan** rather than leaving the two documents disagreeing — a phase file quietly narrowing a criterion the design still states is how a gap becomes invisible.

**Chrome is not a widget layer.** Tier 1 names "chrome" (`:9`), but `stdlib.md:41-47` defers 2D widgets to "a thin immediate-mode helper over LÖVR's `Pass`, not a widget toolkit", and `docs/decisions.md:69` records the toolkit as deferred and possibly a separate library. So chrome here is a handful of `Pass:plane` and `Pass:text` calls. The virtual keyboard sits on the same boundary and is held to the same limit.

## Facts established by investigation

### `win.userdata` cannot carry state across a reload

`docs/architecture.md:41` gives windows a `userdata` field, which looks like the natural place for mullion's per-window state. It is not.

`docs/architecture.md:83` states the Lua state is discarded on soft reload. A `userdata` field holding a Lua table is holding a value from that state, so it does not survive. Anything mullion needs after a reload — a hand-placed pose, a manual size, a tag assignment made by hand rather than by rule — must live outside Lua.

This is why Task 1 exists, and it constrains its design: the store holds plain scalars and strings, never Lua tables, or it reintroduces the same problem one level down.

### The native API has gaps, now fixed in the phases that own them

`CONTRIBUTING.md:62` is explicit: "The standard library uses only the public `lunette` API. If it needs something the API does not expose, that is a defect in the API, not grounds for a private path."

Investigation found six things this phase needs that `docs/` does not document. Decided on 2026-08-06 to fix each in the phase that builds it, so this phase consumes a complete surface. The amendments are already in place:

- **Source pixel dimensions** (`win.width`, `win.height`) — Phase 2, Task 11. Tier 1 cannot convert a ray hit to pixel coordinates without them.
- **`lunette.claimLayer` and `claim:setPriority`** — Phase 3, Task 5. `docs/rendering.md:47-50` described claim semantics but named no function, so layer-versus-quad realisation was unwritable.
- **`lunette.monitors()`** — Phase 4, Task 8. `lovr.lunmonitoradded` was documented (`lua-api.md:32`) with no way to enumerate.
- **`sink:scroll`, in raw and accumulated forms** — Phase 5, Task 4. Tier 2 requires scroll and the plumbing already exists in WayVR (`client.rs:372`, `:408`).
- **A hover-versus-focus primitive** — Phase 5, Task 4. Without it, mullion must infer focus from pointer motion, which is the heuristic Phase 5 deliberately removes from the compositor.
- **Named keymap queries** — Phase 5, Task 4. `docs/input.md:50-52` described them without naming them.

Signals and ray-quad intersection are correctly mullion's own work, not gaps. `docs/lua-api.md:44` says signals are pure Lua over flat events, and `docs/input.md:18-22` says mullion ships the quad intersection.

### A layer is usually larger than its source, and the margin is the panel's to exclude

Phase 3's size ladder quantises upwards, so a claim for an 800x600 window is served by a 1024x1024 layer. The blit copies the source into the corner of the swapchain image, and the rest of the image is memory nothing has written.

Phase 3 put a floor under that rather than leaving it to this phase: the blit clears the destination before a copy that would not cover it, so the margin composites as transparent black instead of as uninitialised memory. The floor is a safety property, not a layout one — it makes the margin blank, not correct.

`claim.width` and `claim.height` report the layer's dimensions rather than the size asked for, and `docs/lua-api.md` documents them as the numbers a caller needs for `layer:setViewport`. Nothing enforces the call. Phase 3 considered enforcing it in the pool and did not: the viewport is one of the per-panel properties that make a layer of a given key serve any panel wanting that key, so setting it from underneath Lua would take away the mechanism a panel needs to place a source inside a larger layer at all.

This phase owns it. A panel that drives the layer path sets the viewport to the source's pixel extent every time it is granted a layer, and again whenever the source resizes.

### LÖVR has no ray-plane intersection

`Mat4`'s method table (`src/api/l_math_mat4.c:442-465`) has no intersection method. The only raycasts in LÖVR are physics: `World:raycast` (`src/api/l_physics_world.c:362`) and `Shape:raycast` (`l_physics_shapes.c:361`), both segment-based and both requiring a physics world and a collider — which a panel is not.

So mullion does the maths. The idiomatic form is to invert the panel's pose matrix, transform the ray origin and direction into panel space, solve for the plane at z=0, and bound the result to ±size/2. `docs/input.md:22` confirms mullion ships this.

### The LÖVR API mullion draws on

- **Textured quad**: `Pass:plane(transform, style, cols, rows)` (`src/api/l_graphics_pass.c:1347`), with the texture bound through `Pass:setMaterial(materialOrTexture)` (`:1330`), which accepts a `Texture` directly. `Pass:cylinder` exists for curved panels later.
- **Hand poses and input**: `lovr.headset.getPose`/`getPosition`/`getOrientation`/`getDirection(device)`, `isDown`/`wasPressed`/`wasReleased`, `getAxis`, `vibrate` (`src/api/l_headset.c:1042-1057`). Device names include `hand/left/point` and `hand/right/point` (`l_headset.c:36`, `:40`) — the pointer-ray poses, which are what lasers should use rather than the hand poses themselves.
- **Text**: `Pass:text(strings, transform, wrap, halign, valign)` (`l_graphics_pass.c:1357`), with `Pass:setFont` (`:1329`).
- **Persistence**: `lovr.filesystem.getSaveDirectory()` (`src/api/l_filesystem.c:403`), `write` (`:422`), `createDirectory` (`:394`). The save directory derives from the identity, not from the source, and Phase 1 points `setSource` at the config directory — so **call `getSaveDirectory()` rather than assuming a path**.
- **Layers**: `Layer:setPose`/`setPosition`/`setOrientation`/`setDimensions`/`setCurve`/`setColor`/`setViewport`/`getTexture` (`src/api/l_headset_layer.c:182-198`). `Layer:getPass` is marked deprecated at `:199`; do not use it.

### Sequencing: teardown and error handling belong here

`docs/roadmap.md:25-26` places the standard library at step 4 and reload, `lunctl`, and error handling at step 5. But two requirements pull parts of step 5 forward:

- `CONTRIBUTING.md:65`: "Every module is safe to `require` twice, and registers a teardown hook."
- `docs/lua-api.md:74`: the error handler "is `mullion` code".

So this phase ships the teardown-hook registry and the `lovr.errhand` replacement. Phase 7 builds the reload mechanism that calls them. Designing the registry here with its caller arriving later is the correct split, not an inversion.

### Module naming is a documentation change

Only two module paths are attested anywhere in `docs/`: `mullion.layout.arc` and `mullion.tag.current`, both from a single example at `docs/lua-api.md:86`. `docs/stdlib.md` names no files and prescribes no module structure at all.

Every other name this phase introduces is new. `docs/` is normative, so choosing them is a documentation change and `docs/stdlib.md` is updated in the same change.

### awesome, for shape only

`docs/decisions.md:11` and `:13` record that awesome is GPL-2, lunette is GPL-3-only, and awesome's code therefore cannot enter the project. `docs/stdlib.md:27` adds that its layout algorithms are two-dimensional and would be reimplemented regardless.

**No awesome code is copied.** What follows is the shape of its designs, which is not copyrightable and is worth learning from.

- **Signals.** `gears.object` gives every object `connect_signal`, `weak_connect_signal`, `disconnect_signal`, and `emit_signal`, with property setters auto-emitting `property::<key>`. The weak variant is the part that matters for lunette: a panel connecting to a window's signal should not keep the window alive.
- **Rules.** A flat ordered list of tables, each with a match clause and either `properties` (values may be functions, evaluated lazily) or callbacks, applied in order with later matches layering on. The engine is factored out into `gears.matcher`, which composes multiple *sources* with declared precedence. That composition is the transferable idea: an `appId` rules table is one source, a saved-layout restore is another, and precedence is declared rather than implicit.
- **Tags.** First-class objects with a name, an index, a `selected` flag, and a layout attached. Clients hold a *set* of tags rather than one workspace id, and selection is multi-select.
- **Persistence.** awesome does not serialise a layout file. Per-client state rides in X properties on the window itself, and rule application is skipped or altered at startup when persistent state exists. lunette has no X server, so the equivalent is Task 1's property store plus a save file — but the important part of the shape is that **restore-on-startup is a distinct source from apply-rules-on-open**, not a special case of it.

---

<!-- START_TASK_1 -->
### Task 1: The per-window property store

**Verifies:** None directly; required by `lunette-v1.AC5.3` and by Phase 7's `lunette-v1.AC5.4`.

**Files:**
- Create: `crates/lunette/src/properties.rs`
- Modify: `crates/lunette/src/lua/window.rs`
- Modify: `docs/lua-api.md`, `docs/decisions.md`

The only native task in this phase. It exists because a soft reload discards the Lua state (`docs/architecture.md:83`), so anything mullion must remember across one cannot live in Lua.

**Step 1: Why `userdata` will not do**

`docs/architecture.md:41` gives windows a `userdata` field, which looks like the obvious place. It holds a Lua value, and Lua values do not survive the state being discarded. State derivable from rules comes back when rules re-run; a hand-placed pose does not.

Record this in the module documentation. `userdata` remains useful for within-session state and should not be removed — the two have different lifetimes and both are wanted.

**Step 2: Plain values only**

The store maps a string key to a scalar or a string, per window. **It does not accept Lua tables.** A table would hold Lua values, which is the same problem one level down.

Enforce it at the boundary with a clear error naming the offending key, rather than silently flattening or serialising. A caller wanting structure encodes it themselves and knows they have.

**Step 3: Lifetime**

Entries live as long as the window does, not as long as the Lua state. A reload leaves them untouched; a window closing drops them.

Persisting the store to disk across a full restart is Task 10's concern, not this one. Keep the two separate: this is a live per-window store, and Task 10 decides what of it is worth writing down.

**Step 4: Stable window identity**

Lua re-associating with its windows after a reload depends on `WindowId` being stable across one. It is — the compositor thread is not restarted by a soft reload — but nothing currently states it. Say so in `docs/lua-api.md`, because the whole reload story rests on it and it is not self-evident.

**Step 5: Document it**

`docs/lua-api.md` gains the store's surface. `docs/decisions.md` gains a paragraph recording why a native store exists at all when `userdata` appears to serve, since the two look redundant to anyone who has not hit the reload case.

Note the lineage: this is awesome's X-properties mechanism adapted to a compositor with no X server. awesome persists per-client state in properties on the window because they outlive the window manager's own process; lunette's store outlives the Lua state for the same reason.

**Step 6: Test**

Cover: a value set before a simulated Lua-state teardown is readable after; a table is rejected with an error naming the key; entries drop when the window closes; `WindowId` is stable across a reload; a key absent returns nil rather than raising.

**Verification:** `cargo test -p lunette`

**Step 7: Commit**

```bash
git add crates/lunette/src/properties.rs crates/lunette/src/lua/window.rs docs/
git commit -m "feat: add a per-window property store that survives reload"
```
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: Mount the standard library and install it

**Verifies:** None directly; without it `lunette-v1.AC5.1`, `AC5.2`, and `AC5.3` cannot pass at all.

**Files:**
- Modify: `crates/lunette/src/boot.rs`
- Modify: `flake.nix`
- Create: `Makefile` or the equivalent install rule

Nothing yet makes `require 'mullion'` resolve. Phase 1 Task 7 deferred mounting the standard library to this phase, and every module Tasks 3 to 10 create lives under `lua/mullion/` where no search path points. Until this task lands, the rest of the phase is unreachable code.

**Step 1: Mount the search path**

`docs/build-and-development.md:41-49` gives the resolution order, and `docs/lovr-integration.md:53` names the mechanism: `lovr.filesystem.setSource`, `mount`, and `setRequirePath`.

The standard library mounts **read-only** from `$PREFIX/share/lunette/lua`, overridable by `LUNETTE_STDLIB_PATH`. Read-only matters: a configuration that can overwrite the standard library it is running on top of can make a session unbootable in a way a reload cannot fix.

State the precedence explicitly rather than leaving it to the mount order: `LUNETTE_STDLIB_PATH` when set, otherwise `$PREFIX/share/lunette/lua`. A user pointing the variable at a working tree is the whole development loop for mullion, so it must win.

**Step 2: The environment variable is read in the binary**

`LUNETTE_STDLIB_PATH` and `$PREFIX` are read at the entry point and passed inward, per `CONTRIBUTING.md:110`. Phase 1 Task 7 established the same rule for the config directory; this extends it rather than introducing a second pattern.

**Step 3: Ordering against `boot.lua`**

`boot.lua` calls `setSource` itself at `etc/boot.lua:131`, deriving the source from `arg` — Phase 1 Task 7 covers that. The standard library mount is separate and comes after, since it augments the require path rather than replacing the source.

Mount before `main.lua` runs. A configuration's first line may be `require 'mullion'`.

**Step 4: Install what the plan ships**

Phase 1 deliberately narrowed the flake to a devshell with no package output, which was right for a phase that shipped no runtime files. This phase ships two sets that must land somewhere:

- `lua/mullion/` to `$PREFIX/share/lunette/lua/` (`docs/stdlib.md:3`).
- `etc/xdg/lunette/main.lua` and `conf.lua` to `$SYSCONFDIR/xdg/lunette/` (`docs/lua-api.md:20`, design plan line 311).

Add an install rule and a flake package output producing both alongside the binary. Without it the mount path in Step 1 points at an empty directory on any machine that did not build in place.

**Step 5: Verify**

Run the installed binary with `LUNETTE_STDLIB_PATH` unset and a default configuration that requires mullion.
Expected: it resolves from `$PREFIX/share/lunette/lua`.

Run it with `LUNETTE_STDLIB_PATH` pointing at the working tree.
Expected: the working tree wins. This is the development loop, so confirm it rather than assuming.

Run: `nix build` and confirm the output tree contains the binary, the standard library, and the default configuration at their documented paths.

Attempt to write to a mounted standard-library file from Lua.
Expected: it fails, confirming the mount is read-only.

**Step 6: Commit**

```bash
git add crates/lunette/src/boot.rs flake.nix
git commit -m "feat: mount and install the mullion standard library"
```
<!-- END_TASK_2 -->

<!-- START_SUBCOMPONENT_A (tasks 3-4) -->
<!-- START_TASK_3 -->
### Task 3: `mullion.signal`

**Verifies:** None directly; used by every later task.

**Files:**
- Create: `lua/mullion/signal.lua`

**Step 1: The surface**

`connect`, `disconnect`, `emit`, and `weakConnect`. `docs/lua-api.md:44` estimates roughly a hundred lines for this, which is about right.

**Step 2: `weakConnect` is not optional**

A panel connecting to a window's signal must not keep the window alive. Without a weak variant, mullion's own bookkeeping pins every window it has ever seen, and the leak is invisible until a long session runs out of memory.

Use a weak-keyed table for weak connections. LuaJIT supports `__mode` normally; this is Lua 5.1 semantics and needs nothing exotic.

**Step 3: Property signals**

Emit `property::<key>` automatically from property setters. This is the whole property-change mechanism and it is what later tasks use to react to a panel moving or a window retitling, rather than polling each frame.

**Step 4: Reload safety**

`CONTRIBUTING.md:65` requires every module to be safe to `require` twice and to register a teardown hook. For this module that means connections do not accumulate across a reload — the registry is rebuilt, not appended to.

Register the teardown hook with Task 4's registry.

**Step 5: Conventions**

LuaJIT, Lua 5.1 syntax, camelCase, comments ending in a period, under the 500-line threshold. No `goto` labels outside LuaJIT's support and no integer division.

**Step 6: Establish the Lua test harness**

This is the first Lua module with tests, so the harness lands here. No earlier phase defines one, and every later task in this phase says "test headlessly" without saying where.

- **Location:** `lua/spec/`, mirroring the module tree — `lua/spec/mullion/signal_spec.lua` for `lua/mullion/signal.lua`. Tests live beside the tree they cover rather than inside it, so an install of `lua/mullion/` does not ship them.
- **Runner:** a plain LuaJIT script, not a framework. These are pure functions over tables; a runner that walks `lua/spec/`, requires each file, and reports failures is under a hundred lines and adds no dependency. `CONTRIBUTING.md`'s rule about not reaching for a dependency for something trivial applies.
- **Fakes:** the `lunette` API is faked, since mullion may use only the public surface and none of it exists in a bare LuaJIT process. One fake table per test file, constructed explicitly, so a test's assumptions are visible in the test.
- **Invocation:** a single command that runs the whole suite, wired into Task 13's check step so it runs alongside the Rust tests rather than being remembered separately.

**Step 7: Test**

Pure Lua, headless. Cover: connect then emit calls the handler; disconnect stops it; a weakly-connected handler does not keep its object alive after a collection; emitting a signal with no handlers is a no-op; `require`ing twice does not duplicate connections; a handler raising propagates rather than being swallowed, per `CONTRIBUTING.md:68`.

**Step 8: Commit**

```bash
git add lua/mullion/signal.lua lua/spec/
git commit -m "feat(mullion): add signals with weak connections"
```
<!-- END_TASK_3 -->

<!-- START_TASK_4 -->
### Task 4: The teardown registry and the error handler

**Verifies:** None directly; required by `lunette-v1.AC5.4` and `AC8.3` in Phase 7.

**Files:**
- Create: `lua/mullion/teardown.lua`, `lua/mullion/error.lua`

Sequenced here rather than in Phase 7 because `CONTRIBUTING.md:65` requires every module to register a teardown hook — so the registry must exist before the first module does — and `docs/lua-api.md:74` says the error handler is mullion code.

**Step 1: The registry**

Modules register a teardown function; reload calls them all before discarding the state. Phase 7 builds the caller; this task builds the registry and the contract.

A module that leaks timers, signal connections, or coroutines across a reload is a defect (`CONTRIBUTING.md:65`). The registry is what makes that checkable rather than aspirational.

Run hooks in reverse registration order, so a module tears down before whatever it depends on.

**Step 2: A hook that fails must not block the rest**

Wrap each hook so one raising does not prevent the others running. Report the failure; a half-torn-down state is worse than a reported error, and reload must complete.

This is a deliberate exception to `CONTRIBUTING.md:68`'s rule against swallowing errors: the error is reported, not swallowed, and teardown is the one place where continuing matters more than propagating.

**Step 3: The error handler**

Replace `lovr.errhand`. Callbacks run under `xpcall` and the handler reports — `CONTRIBUTING.md:68` says not to swallow errors to keep a frame alive.

Rate-limit identical errors. An error raised every frame otherwise produces thousands of identical reports and buries the first one. Key the limit on the message and traceback, and report a count when suppression ends.

Being mullion code makes it replaceable, which is the point of putting it here rather than in Rust.

**Step 4: Test**

Headless. Cover: hooks run in reverse registration order; a hook raising does not prevent later hooks; identical errors are rate-limited and report a count; distinct errors are not conflated; `require`ing twice does not duplicate hooks.

**Step 5: Commit**

```bash
git add lua/mullion/teardown.lua lua/mullion/error.lua
git commit -m "feat(mullion): add the teardown registry and error handler"
```
<!-- END_TASK_4 -->
<!-- END_SUBCOMPONENT_A -->

<!-- START_TASK_5 -->
### Task 5: `mullion.panel`

**Verifies:** `lunette-v1.AC5.1`.

**Files:**
- Create: `lua/mullion/panel.lua`

**Step 1: What a panel is, and is not**

A panel binds a pixel source to a pose and a metre size, chooses between a composition layer and in-scene geometry, converts ray hits to pixel coordinates, and draws chrome (`stdlib.md:9`).

It is **not** a privileged object. `stdlib.md:13`: "a panel is an abstraction built over the primitives, not a privileged object. Windows and sinks can be used without ever creating one." Nothing in the panel implementation may use API a user could not call.

Create from a window or a monitor — both are pixel sources, and after Phase 4's `lunette.monitors()` both are enumerable.

**Step 2: Ray-quad intersection**

LÖVR provides none. `Mat4` has no intersection method (`l_math_mat4.c:442-465`), and the only raycasts are physics-world ones requiring a collider, which a panel has not got.

Invert the panel's pose, transform the ray origin and direction into panel space, solve for z=0, and bound to ±size/2. Return the hit in pixel coordinates using the source's `win.width`/`win.height` from Phase 2.

Handle the degenerate cases explicitly: a ray parallel to the plane has no intersection, and a ray originating behind the panel should not hit its back unless asked to.

**Step 3: Layer versus quad**

Claim a layer through `lunette.claimLayer` with a Lua-chosen priority. When granted, drive the returned `Layer` with `setPose`, `setDimensions`, and friends. When revoked — `lovr.lunlayerrevoked` — fall back to drawing an in-scene quad with `Pass:plane` and a material bound to the source's texture.

Both paths must be live from the start. `docs/rendering.md` treats in-scene as the fallback, not as a degraded mode, and AC2.3 requires the panel to keep rendering after revocation.

Set the viewport on every grant, to the source's pixel extent within the layer `claim.width` by `claim.height` describes. A layer is usually larger than its source, and the blit's clear only makes the margin blank rather than making the panel the right shape; the reasoning is above, under [a layer is usually larger than its source](#a-layer-is-usually-larger-than-its-source-and-the-margin-is-the-panels-to-exclude). A test covers it: a granted claim whose source is smaller than its layer sets a viewport matching the source.

**Step 4: Never cache the texture**

`CONTRIBUTING.md:67`: "Never cache the result of `window:getTexture()` across frames. Textures rotate as the client cycles its buffers." Fetch per frame. Use `surface:stabilize()` where a persistent texture is genuinely wanted, and say why at the call site.

The same applies to `Layer:getTexture()`, which re-acquires from the swapchain.

**Step 5: Check `dead` before use**

`CONTRIBUTING.md:66`: "Never assume a handle survives a frame." A panel holds a source handle that can die between frames. Check before every use, and have the panel remove itself cleanly when its source dies.

**Step 6: Chrome, minimally**

A border and a title, drawn with `Pass:plane` and `Pass:text`. Not a widget layer — `stdlib.md:41-47` defers that and `decisions.md:69` records it as possibly a separate library entirely.

**Step 7: Test**

Ray-quad intersection is pure and gets thorough coverage: a ray through the centre hits at the centre pixel; a ray through a corner hits the corner pixel; a ray missing the bounds returns nothing; a ray parallel to the plane returns nothing; a rotated and translated panel maps correctly; a non-square panel maps both axes independently.

Panel realisation is testable with a fake `lunette` API: a granted claim drives the layer path; a revocation switches to the quad path without losing the panel; a dead source removes the panel.

**Step 8: Commit**

```bash
git add lua/mullion/panel.lua
git commit -m "feat(mullion): add panels over windows and monitors"
```
<!-- END_TASK_5 -->

<!-- START_SUBCOMPONENT_B (tasks 6-7) -->
<!-- START_TASK_6 -->
### Task 6: Lasers and interaction

**Verifies:** None directly; makes `lunette-v1.AC5.1` usable.

**Files:**
- Create: `lua/mullion/laser.lua`, `lua/mullion/interaction.lua`
- Modify: `docs/design-plans/2026-08-05-lunette-v1.md`, `docs/stdlib.md`

The minimum-viable set from `stdlib.md:21`: one laser per hand, hover highlight, trigger-to-click, grab-to-move, and keyboard typing into the focused sink. Plus scroll, which `stdlib.md:17` includes and Phase 5 now exposes.

**Step 0: Amend the design plan for the resize deferral**

Grab-to-resize is deferred, per the scope note. The design plan still lists it in Phase 6's components (line 311) and requires "panels can be grabbed and resized" in its "Done when" (line 317).

Edit both to match: remove resize from the component list and narrow the criterion to grabbed and moved. Record the reason — `stdlib.md:21`'s minimum-viable line omits it, and `:19` makes feel the bulk of the work, so resize is better tuned after move than alongside it. Note it in `docs/stdlib.md` as deferred rather than dropped, since it remains in tier 2's description.

Do this first, so the rest of the task is written against a design that agrees with it.

**Step 1: Use the pointer devices**

`hand/left/point` and `hand/right/point` (`l_headset.c:36`, `:40`) are the pointer-ray poses, distinct from the hand poses. Use them — a laser drawn from the hand pose points where the hand is oriented, not where the runtime says the user is aiming, and the difference is obvious in use.

**Step 2: One seat per hand**

Each laser drives its own seat from Phase 5. Hover and focus are per-seat, so two hands genuinely work independently.

The collapse-to-one-seat mode `docs/input.md:39` mentions is Lua policy over this, and can wait until someone wants it.

**Step 3: Hover versus focus**

Use Phase 5's explicit enter and leave primitive rather than inferring focus from pointer motion. Hovering highlights; clicking focuses. Inferring the two from one signal is the heuristic Phase 5 removed from the compositor, and reintroducing it in Lua would be the same mistake in a different language.

**Step 4: Grab-to-move**

Grip to grab, move the panel with the hand, release to drop. Write the resulting pose into Task 1's property store, so a soft reload does not scramble a hand-arranged workspace — that is the entire reason the store exists.

**Step 5: Feel is the work**

`stdlib.md:19`: "This tier is tuning-heavy. Feel accounts for most of the work."

So this plan specifies structure and leaves constants — highlight thresholds, grab dead zones, laser length, scroll scaling — as named values in one place, tuned in a headset. Do not bury a magic number in the middle of a function; a tuning pass should be a diff to one table.

**Step 6: Teardown**

Lasers hold signal connections and per-frame state. Register a teardown hook. A reload that leaves two lasers per hand is exactly the defect `CONTRIBUTING.md:65` describes.

**Step 7: Test**

The pure parts are testable: given a hand pose and a set of panels, which is hovered; a grab records the right offset; releasing writes the expected pose to the store; scroll deltas map to the expected sink calls. Feel is not testable and is a human gate.

**Step 8: Commit**

```bash
git add lua/mullion/laser.lua lua/mullion/interaction.lua
git commit -m "feat(mullion): add per-hand lasers, hover, click, and grab-to-move"
```
<!-- END_TASK_6 -->

<!-- START_TASK_7 -->
### Task 7: The virtual keyboard

**Verifies:** None directly; supports `lunette-v1.AC4.2` from a headset.

**Files:**
- Create: `lua/mullion/keyboard.lua`

**Step 1: Drive it from the real layout**

Use Phase 5's keymap queries. Legends come from forward lookup — the keysym for a keycode under the current modifiers — and the keycodes come from reverse lookup. Do not hardcode a layout table: a hardcoded QWERTY keyboard lies to every user who is not on QWERTY, and lunette already knows the truth.

Read the layout list so a layout switch is possible later, even if the minimum-viable keyboard does not expose one.

**Step 2: Modifiers**

Use Phase 5's explicit modifier state rather than synthesising modifier keypresses. Sticky modifiers — press shift, then a letter — are the usual expectation for a pointed-at keyboard, since a user cannot hold two keys with one laser.

**Step 3: Text the layout cannot express**

Route through `sink:typeText` rather than trying to synthesise keycodes in Lua. `docs/input.md:58-62` is explicit that the technique requires generating and uploading a temporary keymap and cannot be implemented in Lua.

**Step 4: Draw it minimally**

`Pass:plane` and `Pass:text`, same constraint as panel chrome. This sits on the boundary of the deferred widget toolkit and must not cross it.

**Step 5: Test**

Legend generation and keycode resolution are pure given a keymap: legends match the layout; a key produces the expected keycode and modifiers; a sticky modifier applies to the next key and then clears; a character the layout cannot express routes to `typeText` rather than to `sink:key`.

**Step 6: Commit**

```bash
git add lua/mullion/keyboard.lua
git commit -m "feat(mullion): add a virtual keyboard driven by the real layout"
```
<!-- END_TASK_7 -->
<!-- END_SUBCOMPONENT_B -->

<!-- START_SUBCOMPONENT_C (tasks 8-10) -->
<!-- START_TASK_8 -->
### Task 8: Tags and the arc layout

**Verifies:** None directly; required by `lunette-v1.AC5.3`.

**Files:**
- Create: `lua/mullion/tag.lua`, `lua/mullion/layout/arc.lua`

**Step 1: Tags as objects, membership as a set**

Follow awesome's shape, not its code: a tag is an object with a name, an index, a selected flag, and a layout attached, and a panel belongs to a *set* of tags rather than to one workspace.

The set is what makes "show this panel on two tags" expressible without special-casing, and multi-select is what makes viewing two tags at once possible. A single-current-workspace model cannot be widened into either later without breaking every caller.

`mullion.tag.current` is one of only two module paths `docs/` attests (`docs/lua-api.md:86`), so that name is fixed.

**Step 2: One arc layout**

`mullion.layout.arc` — the other attested name — arranges the current tag's panels in an arc at a comfortable radius (`stdlib.md:29`).

Written from scratch. `stdlib.md:27`: "awesome's algorithms are two-dimensional and GPLv2, so this tier is reimplemented from scratch regardless." An arc in three dimensions has no awesome equivalent to reimplement in any case.

Parameters — radius, arc span, panel spacing, height — go in one table, for the same tuning reason as Task 6.

**Step 3: A layout is a function**

A layout takes a set of panels and assigns poses. That keeps a user-written layout exactly as capable as a built-in one, which is the point of a standard library that is replaceable.

**Step 4: Test**

Pure. Cover: n panels arranged in an arc are equidistant from the centre and evenly spaced; one panel sits at the arc's midpoint; zero panels is a no-op rather than a division by zero; membership in multiple tags does not duplicate a panel in one tag's layout; a tag with no selected state does not participate.

Include the degenerate cases explicitly rather than trusting a generator to find them.

**Step 5: Commit**

```bash
git add lua/mullion/tag.lua lua/mullion/layout/arc.lua
git commit -m "feat(mullion): add tags and an arc layout"
```
<!-- END_TASK_8 -->

<!-- START_TASK_9 -->
### Task 9: Rules

**Verifies:** `lunette-v1.AC5.2`.

**Files:**
- Create: `lua/mullion/rules.lua`

**Step 1: The shape**

A flat ordered list of tables, each with a match clause on window properties — `appId` at minimum — and a `properties` table applied on match. Rules apply in order and later matches layer on.

Property values may be functions, evaluated lazily at application time. That is what lets a rule say "place this on the current tag" rather than baking in whichever tag was current when the config loaded.

**Step 2: Sources, not one list**

Take awesome's `gears.matcher` idea as shape: multiple *sources* composed with declared precedence, rather than one list with implicit ordering.

The `appId` rules table is one source. Task 10's saved-layout restore is another. Declaring that restore beats rules — or does not — is then a statement in the configuration rather than an accident of call order. Task 9 depends on this being expressible.

**Step 3: No awesome code**

awesome is GPL-2 and lunette GPL-3-only, so its code cannot enter this project (`docs/decisions.md:11`, `:13`). Only the design shape is taken, which is not copyrightable. Write it fresh, and do not consult its source while writing this file.

**Step 4: Apply on open**

A rule matching a newly spawned window places it with no further scripting (AC5.2). Hook the window-opened event.

**Step 5: Test**

Pure over synthetic window tables. Cover: a rule matching `appId` applies its properties; a non-matching rule does not; two matching rules layer in order; a function-valued property is evaluated at application time, not at definition time; an empty rules table is a no-op; a rule matching on an absent field does not match rather than erroring.

**Step 6: Commit**

```bash
git add lua/mullion/rules.lua
git commit -m "feat(mullion): place windows by appId rules"
```
<!-- END_TASK_9 -->

<!-- START_TASK_10 -->
### Task 10: Layout persistence

**Verifies:** `lunette-v1.AC5.3`.

**Files:**
- Create: `lua/mullion/persist.lua`

**Step 1: Call `getSaveDirectory`, do not assume it**

`lovr.filesystem.getSaveDirectory()` (`src/api/l_filesystem.c:403`). The save directory derives from the identity, not from the source, and Phase 1 points `setSource` at the config directory — so the save path is not the config path and must not be guessed.

**Step 2: What to save**

Enough to reconstruct an arrangement: which panels existed, their sources' identities, poses, sizes, and tag membership.

Key on something stable. A window's `appId` plus a slot survives a restart; a `WindowId` does not, since the compositor is restarted too. Monitors have Phase 4's descriptor-or-connector identity, which is exactly the stable key this needs.

**Step 3: Restore is a separate source**

Restore-on-startup is a distinct source from apply-rules-on-open, composed through Task 9's precedence rather than special-cased.

This is awesome's distinction, and the reason for it is concrete: after a restart a window that was hand-placed should return to where it was, while a window opening fresh should be placed by rule. Collapsing the two makes one of those cases wrong, and which one depends on ordering.

**Step 4: Handle a stale save**

A saved arrangement may reference a monitor that is gone or an application that is not running. Restore what matches, report what did not, and do not fail the whole restore because one entry is stale. A configuration that refuses to load because a monitor was unplugged is worse than one that loads partially and says so.

**Step 5: Live state versus saved state**

Task 1's property store holds live per-window state across a reload. This task decides what of it is worth writing to disk for a restart. They are different lifetimes and different mechanisms; keep them separate and say so.

**Step 6: Test**

Serialisation and restore are pure over tables. Cover: a saved arrangement round-trips; a stale entry is skipped and reported while the rest restores; an absent save file yields defaults rather than an error; a save written by an older version loads or is rejected explicitly rather than partially applied; restore and rules compose in the declared precedence.

The round-trip earns its place here: this is a file format that outlives the process, which is exactly the case `CONTRIBUTING.md:142` says a round-trip test is for.

**Step 7: Commit**

```bash
git add lua/mullion/persist.lua
git commit -m "feat(mullion): save and restore arrangements"
```
<!-- END_TASK_10 -->
<!-- END_SUBCOMPONENT_C -->

<!-- START_TASK_11 -->
### Task 11: The default configuration

**Verifies:** `lunette-v1.AC5.1`, `lunette-v1.AC5.2`.

**Files:**
- Modify: `etc/xdg/lunette/main.lua`

**Step 1: Keep it small**

`stdlib.md:39`: "the default config spawns a terminal, shows it on a panel, and provides a laser and a reload key. Nothing more."

Resist adding more. The default configuration is read by every new user as the worked example of how mullion is meant to be used, and a large one teaches that a large one is necessary.

**Step 2: Where it ships**

`$SYSCONFDIR/xdg/lunette`, per `docs/lua-api.md:20` and the design at line 311. Phase 1 established the config directory resolution; this replaces the placeholder written there.

**Step 3: A config need not use mullion**

`docs/lua-api.md:22`: "A config that never mentions `mullion` is a supported configuration." The default one does use it, but nothing in the loading path may assume that.

**Step 4: Verify**

Human gate: the default configuration spawns a terminal onto a panel, the panel can be grabbed and moved, a rule places a named application, and an arrangement survives a restart.

**Step 5: Commit**

```bash
git add etc/xdg/lunette/main.lua
git commit -m "feat: ship a default configuration built on mullion"
```
<!-- END_TASK_11 -->

<!-- START_TASK_12 -->
### Task 12: Embedded safe mode

**Verifies:** None directly; the payload for `lunette-v1.AC8.4` in Phase 7.

**Files:**
- Create: `crates/lunette/src/safe_mode.rs`

**Step 1: Embedded, and self-contained**

Decided on 2026-08-06: safe mode is a short Lua string compiled into the binary.

`docs/lua-api.md:76` says "The native layer owns exactly one failure path", which implies embedded, and the reasoning holds up. Safe mode exists for when `main.lua` fails to load. mullion may be *why* it failed — a broken standard library, a missing install, a bad `LUNETTE_STDLIB_PATH`. So safe mode **must not `require 'mullion'`**, and uses only the `lunette` API.

**Step 2: What it does**

A laser, one panel, a terminal, and a reload key (`docs/lua-api.md:76`). Enough to see something, fix the configuration from inside the headset, and reload — rather than removing the headset to edit a file.

This duplicates a little of Task 11's default configuration. That duplication is the price of it always working, and it should be noted at both sites so neither is "simplified" by pointing at the other.

**Step 3: The trigger is Phase 7's**

Phase 7 wires safe mode to a `main.lua` that fails to load. This task provides the payload, next to the default configuration it deliberately resembles, so the two stay in step.

**Step 4: Test**

The embedded chunk compiles and runs against a fake `lunette` API without touching `package.loaded`, and raises nothing when the standard library is entirely absent.

**Verification:** `cargo test -p lunette`

**Step 5: Commit**

```bash
git add crates/lunette/src/safe_mode.rs
git commit -m "feat: embed a self-contained safe mode configuration"
```
<!-- END_TASK_12 -->

<!-- START_TASK_13 -->
### Task 13: Check suite and gates

**Verifies:** All Phase 6 criteria.

**Step 1: Run the check suite**

All five commands from `CONTRIBUTING.md:171-175`, inside `nix develop`.

**Step 2: Run the Lua tests headlessly**

Run the `lua/spec/` suite through the harness established in Task 3. The pure modules — ray-quad intersection, rule matching, arc placement, signals, persistence round-trips — run without a headset or a GPU.

Confirm every module under `lua/mullion/` has a corresponding spec file. A module with no spec is not necessarily a defect — some are thin — but the absence should be deliberate rather than accidental.

**Step 3: Check reload safety mechanically**

For each mullion module: `require` it twice and assert no duplicate signal connections, no duplicate teardown hooks, and no accumulated timers. `CONTRIBUTING.md:65` makes this a defect class, so check it rather than trusting review.

**Step 4: Check the file-size threshold**

`CONTRIBUTING.md:69` sets it at roughly 500 lines for Lua. Check each module and split along a natural seam where one exceeds it — not at the line count.

**Step 5: Confirm mullion uses only the public API**

Grep the standard library for anything not in `docs/lua-api.md`. `CONTRIBUTING.md:62` makes a private path a defect in the API, not an acceptable shortcut, and this is the check that keeps it honest.

**Step 6: The human gates**

- The default configuration spawns a terminal onto a panel at the specified pose and metre size (AC5.1).
- Panels can be grabbed and moved, and the placement feels right — the tuning pass.
- A rule places a named application without further scripting (AC5.2).
- An arrangement survives a restart (AC5.3).

**Step 7: Commit**

Only if the check suite produced changes.
<!-- END_TASK_13 -->

---

## Done when

- The default configuration spawns a terminal onto a panel.
- Panels can be grabbed and moved.
- A rule matching on `appId` places a named application.
- An arrangement survives a restart.
- Every mullion module registers a teardown hook and is safe to `require` twice.
- mullion uses only the documented public API.
- All five check commands pass.

## Deliberately not in this phase

- **Grab-to-resize.** In tier 2's description (`stdlib.md:17`) but not its minimum-viable line (`:21`). Deferred until move has been tuned in a headset.
- **A 2D widget toolkit.** `stdlib.md:41-47` and `docs/decisions.md:69` defer it, possibly to a separate library. Chrome and the keyboard stay within `Pass:plane` and `Pass:text`.
- **Further layouts** — wall grid, stack, follow-head-with-lag (`stdlib.md:25`). One arc is the minimum viable set.
- **The reload mechanism itself.** This phase ships the teardown registry and the error handler; Phase 7 builds the caller and the safe-mode trigger.
- **Per-panel output scale**, which changes a panel's requested size — Phase 8.
- **Notifications, dashboards, and launcher furniture**, recorded as out of scope for v1 in the design.

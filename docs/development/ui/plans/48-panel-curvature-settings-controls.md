# Persistent panel properties: one store, shared geometry, locks and curvature

## Goal

Give every application, monitor, and toolkit panel one persistent properties model and one Settings menu.
The header's gear opens Settings with the bend, axis, input lock, and transform lock; quick `I` and `T` lock icons sit left of the gear while each property is relevant.
Input lock affects only the panel's contents: the header band and Settings overlay stay usable.
Transform lock stops user movement and resizing, including size, while owner placement continues to work.
All properties are stored in one new versioned properties store shared by window, mirror/monitor, and toolkit panels.
The geometry that maps pointer rays to the curved surface is one shared implementation.
The arrangement keeps panel placement data only.

This is the full implementation of [#48](https://github.com/philpax/lunette/issues/48) plus the properties menu and both lock axes.

## Implementation Summary

The existing input lock is a native panels property that denies content input while the titlebar, a separate UI panel, stays usable.
The new transform lock is a surface property checked by the pointer grab path, so it applies to native and toolkit panels alike.
Toolkit input lock is content-only: the UI host's pointer, touch, and focus routers reject content nodes while allowing a `lockFree` header band and the separately mounted Settings overlay.
A shared controller drives the Settings popup and the quick locks; the default controller targets the toolkit panel that owns the header, and the decorations titlebar supplies one targeting its native panel. The native titlebar's old Lock input action is removed.
One `PanelProperties` value and one `PanelId` identity union live in a neutral contract. A new properties store in `layout/persistence` persists that value for all three panel families in one versioned file. The arrangement keeps pose, size, and tags; its next version removes the input lock, and the store migrates that lock from the current arrangement.
The native panels service and the UI host become producers of the shared properties value and change events; the store is a consumer.
The cylinder hit/frame/mapping maths is factored into one shared library used by `panels/service/private/shape.luau` and `ui/host/private/shape.luau`; rendering stays on each family's existing path (composition layer or CPU mesh for natives, host shader for toolkit panels).
The standard `Button` gains an icon and active state for the gear and lock icons; monochrome SVGs are tinted by the button ink.

Affected areas:

- `lua/lunette-contracts/panel-properties.luau` (new): `PanelProperties`, `PanelId`, and the properties-store contract types.
- `lua/lunette-contracts/vocabulary.luau`: `Surface.transformLocked`.
- `lua/lunette-contracts/ui-host.luau`: `Bend`, `Actions.bend`/`setCurve`/`locked`/`setLocked`/`transformLocked`/`setTransformLocked`/`transformAvailable`, panel reads/setters, panel-added/properties-changed listeners, `lockFree` kind registration, content-lock guarantees; capability version 2.
- `lua/lunette-contracts/panels.luau`: runtime `setCurve`, `transformLocked`/`setTransformLocked`, `onCurveChanged`/`onTransformLockChanged`, and explicit-property reads; capability version 6.
- `lua/lunette-plugins/graphics/curved-surface.luau` (new): shared curvature, half-angle, ray/hit, panel-coordinate, and frame maths.
- `lua/lunette-plugins/interaction/pointers/`: the `transformLocked` grab check and in-flight detach.
- `lua/lunette-plugins/ui/host/`: bend/record mutators, content lock, header `lockFree`, panel-added/properties-changed listeners, surface `transformLocked`.
- `lua/lunette-plugins/ui/standard/private/`: `curvature.luau`, `settings.luau`, `icons.luau`, `actions.luau` (icon/active Button), `structure.luau` (Panel properties), and `values.luau` (`showHeading`).
- `lua/lunette-plugins/panels/service/`: runtime curve, transform lock, layer fallback, and the shared curved-surface maths.
- `lua/lunette-plugins/panels/decorations/`: the native properties controller, quick locks, Settings, and titlebar follow.
- `lua/lunette-plugins/layout/persistence/`: the new properties store, identity/slots, migration, and arrangement version 3.
- `lua/lunette-plugins/window/placement/`: rule options without arrangement-owned properties.
- `lua/lunette-plugins/input/keyboard-display/private/titlebar.luau`: no Settings control.
- Tests and documentation across interaction, panels, decorations, UI, graphics, persistence, and user/plugin guides.

### Scope decisions

- **One properties-only store.** `panel-properties.saved` owns `curve`, `curveAxis`, `inputLocked`, and `transformLocked` for every panel family. It does not own pose, size, tags, or placement. Window and monitor placement stay in the arrangement and placement memory; toolkit pose placement stays in placement memory/its owner.
- **The arrangement keeps placement data only.** The next arrangement version keeps kind, key, slot, pose, size, and tags; it removes the input lock. The properties store takes over the input lock, curve, and transform lock. The current version 2 input lock migrates into the new store on first start.
- **Identity is a closed union.** `PanelId` is a window application id plus slot, a monitor key plus slot, or a toolkit panel name. The store reuses the arrangement's held-slot resolution for native panels, and the panel name for toolkit panels.
- **A creator or rule explicit property wins at creation.** The store fills only properties the creator omitted. This keeps designed wraps and configuration locks intact.
- **Input lock is content-only.** Native content is a sink; the titlebar is separate. Toolkit content is host nodes; the host exempts a `lockFree` header band and the Settings overlay. A locked toolkit panel always keeps a way to unlock.
- **Transform lock is gesture-only and includes size.** The pointer grab path refuses grip, titlebar trigger-drag, and two-handed resize; owner `setPose`/`setSize`, rules, and restore still work. An in-flight grab is detached when the lock engages.
- **The locks are independent.** Input lock preserves spatial grabs; transform lock leaves content interactive.
- **The header shows a gear and contextual lock icons.** The gear is a `Button` with a gear SVG and the accessible name "Settings"; the popover heading is "Settings". Its left shows a lock with `I` when input lock is available and a lock with `T` when transform lock is available. Each is an icon-only `Button` with an active state and a state label ("Input locked"/"Input unlocked", "Transform locked"/"Transform unlocked"). The Settings popover also contains both toggles.
- **Window and monitor panels bend about the vertical only.** Their bend is `0..180°` and the axis row is disabled with "Window and monitor panels bend about the vertical." Toolkit panels offer the signed bend and full axis.
- **The cylinder maths is shared.** One `curved-surface` library provides curvature, half-angle, ray/hit, panel coordinate, and frame conversion. Native panels keep the positive-vertical restriction and their layer/CPU mesh rendering; toolkit panels keep signed/axis and the host shader.
- **Dialogs and the keyboard titlebar are excluded.** A dialog's header is not the standard Panel; the keyboard titlebar attaches to an input surface and has no Properties control.
- **The control form departs from #48's earlier curvature-handle note.** A header gear, quick locks, and popup work on native titlebars and toolkit panels and stay controller-reachable.

## Version control and commit strategy

Work happens on a dedicated branch, never on the current branch:

1. Confirm the working tree is clean with `git status --short`. If it has unrelated changes, stop and ask rather than carrying them into this branch.
2. Create the branch from the current `HEAD`: `git switch -c feat/panel-properties`.
3. Keep the branch local unless the operator asks to push. Never force-push, amend a commit created by someone else, or bypass hooks.
4. Commit in coherent slices after each phase, with the tests and docs that cover that slice in the same commit. Do not squash the work into one commit at the end.
5. Each commit should leave its targeted checks green: `make check-luau`, `make check-luau-annotations`, the relevant `cargo test -p lunette --test lua` suites, and `make check-format`. `make check` is the final gate; cross-phase fixes become follow-up commits, not history rewrites.
6. If generated declarations change (none expected), run `cargo run -p lunette-generate-definitions` and commit the result with the change that caused it.
7. Commit subjects are short, imperative, and sentence case, for example `Add shared panel properties`, `Add content-only input lock`, `Add the panel properties store`. The body states why, and names the persistence/version decisions when the commit touches them.

Expected slices:

- `Add shared panel properties and curved-surface maths`: `panel-properties`, `vocabulary.transformLocked`, `graphics/curved-surface`, the allowlist, and their tests.
- `Add native runtime curvature and transform lock`: panels service, interaction pointer guard, layer fallback, and tests.
- `Add UI host content lock and panel properties events`: UI host capabilities, mutators, content routing, listeners, and tests.
- `Add standard Settings and lock icons`: Settings module, icons, Button icon/active, Slider heading, and tests.
- `Add native titlebar properties`: decorations controller/follow, keyboard opt-out, and tests.
- `Add the panel properties store and arrangement version 3`: layout/persistence store, identity, migration, arrangement v3, rules/window placement, and tests.
- Documentation lands with the behaviour it describes; a final docs-only commit is acceptable only for cross-cutting user/plugin overview text.
- `Run full checks and fix regressions`: the final `make check` fixes, if any.

Add an optional final `git log --oneline` review to confirm the slices are coherent before handoff.

## Implementation Plan

### Phase 0: Branch and baseline

- Confirm a clean tree and create `feat/panel-properties`.
- Record the baseline check state without fixing unrelated failures. If the baseline already fails a required check, report it and keep the failure out of this branch's scope unless it blocks the work.
- Confirm submodules are present; no LÖVR or `wlx-capture` changes are expected.

### Phase 1: Shared value, identity, and curved-surface maths

1. Add `lua/lunette-contracts/panel-properties.luau`:
   ```luau
   export type PanelProperties = {
     read curve: number,
     read curveAxis: number,
     read inputLocked: boolean,
     read transformLocked: boolean,
   }
   export type PanelId =
     { read kind: 'window', read appId: string, read slot: number }
     | { read kind: 'monitor', read key: string, read slot: number }
     | { read kind: 'toolkit', read name: string }
   ```
   Add `encodeId`/`decodeId` for the store's map keys and a `propertiesOf` adapter for the panel families.
2. Add `lua/lunette-plugins/graphics/curved-surface.luau`:
   - `curvature(width, height, curve, axis)`: the across-axis extent and the full-turn clamp.
   - `halfAngle(width, curve)` and `limit(width, curve)` as the single shared clamp.
   - `toPanel`, `ray`, and `frame`/`localRay` for a panel pose, width, height, curve, axis, and scale; the native adapters pass scale 1, the toolkit adapters pass the panel zoom.
   - The native panels use the positive-vertical subset; the toolkit host uses signed and tilted. The shared module is a pure library, not a contract.
   - Add `graphics/curved-surface.luau` to the shared-module allowlist in `crates/lunette/tests/plugin_dependencies.rs`; document it in `lua/lunette-plugins/graphics/README.md` (the plugins README table is for removed-path migration, not new modules).
   - `cargo test -p lunette --test plugin_dependencies` is part of the gate.
3. Refactor:
   - `panels/service/private/shape.luau` uses `curved-surface` for hit and half-angle/limit; its mesh builders (`arc`, `rounded`, `mapTriangles`, `SEGMENTS`) stay in the native module and keep CPU mesh generation. It has no frame maths.
   - `ui/host/private/shape.luau` uses `curved-surface` for curvature, ray/hit, frame, and local ray; its renderer keeps its shader path.
   - Tests prove the native and host hit conversions use the same shared maths.
4. Add `Surface.transformLocked` to both `SurfaceFields` and the duplicate `MovableFields` alias in `vocabulary.luau`; it is independent of `locked` and `grabbable`.
5. In `lua/lunette-plugins/interaction/pointers/init.luau`:
   - After resolving the grab target (`hit:grabTarget()`), check both the hit surface and the resolved target for `transformLocked` before `beginGrab`.
     Also check `target.transformLocked` inside `beginGrab`, which is the unbypassable guard for every caller.
     This covers the native titlebar's trigger drag, the grip, and the two-handed resize; the titlebar surface resolves to the native panel.
   - In the pointer update, if the grabbed or scaling target becomes `transformLocked`, end the grab through `grab.detachGrab`. The surface flag is read live; no UI host event is needed.
   - Tests in `interaction/pointers/tests/locks.luau` use a fake surface exposing `transformLocked`, `triggerGrabs`, and `grabTarget`: `a transform-locked panel refuses grip and trigger grabs while content input still works` and `a grab in flight ends when the panel is transform-locked`.

### Phase 2: Native panels: runtime curve, transform lock, and explicit properties

1. `panels.luau`:
   - `PanelFields` add `curve` (existing read), `setCurve(Panel, number, boolean?)`, `transformLocked`, `setTransformLocked(Panel, Owner, boolean)`, and explicit-property reads (`curveExplicit`, `lockedExplicit`, `transformLockedExplicit`).
   - `Service` add `onCurveChanged` and `onTransformLockChanged` beside `onLockChanged`.
   - `Options` add `transformLocked`; `locked` remains the input lock.
   - Bump the capability to version 6.
2. `panels/service/private/panel.luau`:
   - `Host` gains `curveChanged` and `transformLockChanged`.
   - `setCurve` validates with `checkCurve`, skips only an unchanged non-commit, and always notifies on commit.
   - `setTransformLocked` mirrors `setLocked`: owner check, unchanged skip, update, notify.
   - The record stores the creation options' explicit flags; the panel surface publishes `transformLocked`.
   - The panel records `curveAxis = 0` for the shared value.
3. `panels/service/init.luau`: add the transform listener, clear it on shutdown, include it in inspection.
4. Layer fallback and clamped curvature:
   - A window with a positive curve claims a cylinder layer only when `lovr.headset.getFeatures().layerCurve` is true; otherwise it releases the layer and draws in the scene. Monitors always draw in the scene.
   - The service caches `layerCurve` once at build before the first claim and refreshes it once per update.
   - The layer drive uses the shared `curved-surface.limit`; the mesh/hit paths already use the shared half-angle, so one clamp serves both.
5. Extend `lua/testing/native.luau` with `events.layerCurve`, `getFeatures(): { read eyeTracking: boolean, read layerCurve: boolean }` defaulting to true, and a per-name `events.fileWrites[name]` counter for non-`.state` saves (the arrangement's `.state` counter stays). The layer-support test sets `events.layerCurve` explicitly.
   Add a fake test for the counter; the store's no-write assertions use `events.fileWrites['panel-properties.saved']`.

### Phase 3: UI host: content lock, shared value, and listener seams

1. `ui-host.luau`:
   - Add `Bend` (`curve`, `axis`, `width`, `height`).
   - `Actions` gain `bend`, `setCurve(curve, axis, commit)`, `locked`, `setLocked`, `transformLocked`, `setTransformLocked`, `transformAvailable`.
   - `Panel` gains `curve`, `setCurve` with optional commit, `locked`/`setLocked`, `transformLocked`/`setTransformLocked`, `grabbable`, and `properties` (`PanelProperties`).
   - `PanelOptions` gains `locked` and `transformLocked`.
   - `KindRegistration` gains `lockFree`; the standard `lunette/header-band` registers `lockFree = true`.
   - `Service` gains `onPanelAdded(owner, listener)` and `onPropertiesChanged(owner, listener)`, plus `read panels: (Service) -> { { panel: Panel, options: PanelOptions } }` for the live top-level panels, so the store can apply its world-only membership filter at bind.
     The host's `Live` entries retain the creation options; a bare handle lacks `presentation`.
     Overlay records have no public handle, so they are excluded by handle-bearing; do not filter by `options.presentation` alone, because overlay records default to world.
     The panel-added listener receives the handle and its options; the changed listener receives the handle.
   - `ui/host/private/registry.luau`'s `REGISTRATION_FIELDS` whitelist gains `lockFree`; the registry rejects unknown fields, so this is required before the header band can register it.
     These events cover top-level panels; overlay panels have no public handle and are excluded from the properties store.
   - Bump the capability to version 2.
2. Record mutators:
   - `records.Panel` gains `setCurve(curve, axis, commit)`, `setLocked(locked, commit)`, `setTransformLocked(locked, commit)`.
   - Define them in `panel.record`, which takes the provider/commit callback; `panel.new` and `overlay.render` pass it, and the direct test caller in `ui/host/tests/panel.luau` is updated.
   - The handle and `handles.actions` call the record mutators. A commit with an unchanged value still fires the properties-changed event; a non-committing unchanged value is a no-op.
   - The properties-changed event fires on commits and discrete lock toggles, not on curve previews. The store saves from it.
3. The host has no properties setting:
   - The UI host does not store panel properties; the properties store is the only writer.
   - `newPanel` does not restore properties; the store applies them from `onPanelAdded`.
   - The host's settings stay `placed` (legacy read), touch, controllerTraversal, and appearanceChord.
4. Content-only input lock:
   - The pointer hover/press choke point is `input.target`; add the content-lock check there, and separately guard the scroll path and `touch`/`poke`.
     Because `input.target` returns nil over locked content, `input.grabs` can still report a header/handle grab. This is intended: input lock preserves spatial grabs (AC.8); a trigger press on locked content may begin a spatial grab but never activates the content.
   - A node with a `lockFree` ancestor is allowed; a content node on an input-locked panel is refused. The Settings overlay is a separate panel.
   - The record's `setLocked(true)` calls `provider.cancelContent(record)` before applying the flag, so the cancellation helper has an explicit call site.
   - Export `input.cancelContent(router, env, panel, isContent)` to bump the generation, dispatch `cancel` to content captures, reset `pressed`/`dragging`, clear content hovers and handoffs, and clear a locked content node's touch marker; export `poke.reset(hand)`. `Provider.cancelContent(record)` in `ui/host/init.luau` delegates.
   - `focus.policy` returns `'none'` for content nodes on an input-locked panel; `setLocked(true)` blurs a focused content node.
   - The UI host surface does not publish `inputLocked` as `Surface.locked`; that would block the header and Settings. The host routers enforce content-only; the surface stays unlocked.
5. Surface `transformLocked`:
   - The UI host surface publishes `transformLocked` in `record.sync`; `setTransformLocked` calls `record.sync()`.
   - The setter updates the record and fires the properties-changed event on the discrete toggle.
6. The UI panel's `properties` read builds `PanelProperties` from `curve`, `curveAxis`, `locked`, and `transformLocked`; the store's adapter uses it.

### Phase 4: Standard UI: Settings, quick locks, and icons

1. `actions.luau`:
   - Add `icon = optional(shapes.image)` and `active = optional(schema.boolean())` to `Button`.
   - When `icon` is set, `expand` omits the label text child; the `lunette/button-face` visual draws an `lunette/image` at `theme.sizes.control * 0.6` with `tint = tokens.ink(theme, ink)`, because the visual has the theme and the expand does not. `label` remains the accessible name.
   - `active` composes with `variant`: the base fill stays, the ink becomes the selected ink, the elevation becomes `theme.elevation.selected`; the semantics expose `selected = props.active == true`.
2. Add `icons.luau`: monochrome SVGs for the gear, a lock with `I`, and a lock with `T`; the lock silhouettes are identical except the letter. The `I`/`T` are paths, not SVG `<text>`, because `lunette.rasterizeSvg` does not draw text elements.
3. Add `curvature.luau`: `MAX_BEND = 180`, `MAX_AXIS = 180`, `read`, `curve`, `parse`, `format` (signed total arc, axis wrapped into `(-180, 180]`, zero-size `0,0`).
4. Add `settings.luau`, requiring `curvature` and `icons`:
   - The `Controller` and `Lock` types, with `available` and `reason`, `axisReason`, `bend`, `setCurve`, `axis`, `negative`, `inputLock`, `transformLock`; `settings.schema` is the controller prop schema; a nil controller uses the Panel's own `act`.
   - `settings.control`:
     - A `lunette/row` keyed `settings`: the `input-lock` and `transform-lock` icon buttons (shown when available, active from the Panel state, state labels), then the gear `Button` labelled "Settings".
     - A `lunette/portal` keyed `popup`, `placement = 'above'`, only while `state.settingsOpen`. A closed Settings menu emits no portal, so every titled panel does not grow a permanent overlay; `onDismiss` clears the open state and reverts an uncommitted preview.
     - `lunette/menu` containing a `body` column: the "Settings" heading; Bend/Axis columns with a `heading` row (label + `text-field` `value`) and an unkeyed slider whose track is `track`; the axis disabled with `axisReason`; an "Interaction" section with `lunette/toggle` rows for Input lock and Transform lock, disabled with `reason` when unavailable.
     - The quick icons and toggles write the Panel state with `act.setState` and call the lock setter, so the Panel re-expands and both copies show the new state.
     - The first expand seeds `inputLocked`/`transformLocked` from the controller; the seed writes only while the field is unset (a `seeded` flag), so it settles after one re-expand and does not mark the node dirty forever.
     - A change made outside the Settings control is reflected on the next panel re-expand (the titlebar's locked suffix changes the title, opening the popup re-expands, and other panel state changes do the same). Add `an external lock change is reflected on the next re-expand`; the plan does not add a live subscription.
     - The `Actions` property reads are expansion-time values: a popup opened before an external change shows the value seeded at open, not a live subscription. An external change while open is observed on reopen; if live external updates are wanted later, the host's properties-changed listener can schedule the panel.
     - Curve previews apply without saving; release/submit commits; invalid text marks the field and never applies; closing/dismissing reverts an uncommitted preview.
5. `structure.luau`:
   - `Panel` props gain `propertiesControl` and `properties` (the controller schema).
   - The Panel state gains `settingsOpen`, `inputLocked`, `transformLocked`, the curve fields, and the invalid flags.
   - `Panel`'s `expand` takes `(props, children, state, act)`; the host already passes them.
   - `expand` appends `settings.control(...)` to the `actions` array passed positionally to `lunette/header`, after caller `HeaderActions` and before close, when `props.title ~= nil and props.propertiesControl ~= false`.
   - The header schema is unchanged; dialogs' direct header is unaffected.
   - `lunette/header-band` registers `lockFree = true`.
6. `values.luau` adds `showHeading` to `Slider`, omitting the heading and detent labels when false; `ui-components` comments update; the service stays at version 1 because kind props are not the service shape.

### Phase 5: Decorations titlebar

1. `controls.luau`:
   - Remove the `lock` action; keep monitor restart/select.
   - Add an optional `properties` controller for the native target: `bend`/`setCurve`; `axis = false`; `negative = false`; `inputLock` get `target.locked` and set `target:setLocked(context, value)`; `transformLock` get/set `target.transformLocked`; both available.
   - `sameContent` ignores the controller.
2. `init.luau`:
   - Pass `properties = options.properties` and `propertiesControl = options.properties ~= nil` to the titlebar's `c.Panel`.
   - Set the titlebar's own curve to the target's curve each refresh with a non-committing `setCurve(target.curve, 0)`; the titlebar never writes a properties entry.
   - The input lock leaves the titlebar and Settings usable; the transform lock stops the titlebar trigger drag but not its buttons.
   - The `' [locked]'` title suffix for the input lock remains.
3. `input/keyboard-display/private/titlebar.luau` passes `propertiesControl = false`.
4. The joined native outline detaches when the target curves; the titlebar's curved surface and gap carry the chrome.

### Phase 6: One properties store in `layout/persistence`

1. Add `layout/persistence/private/properties.luau`; do not add a parallel format module:
   - Use the shared `lua/lunette-plugins/storage/versioned-file.luau` for read/render/atomic write and the newer-version refusal.
   - Store version 1, file `panel-properties.saved` (not a `.state` name, so the Lua fake keys saved files by name), a map of encoded `PanelId` to `PanelProperties`.
   - `versionedFile.write` raises on failure; the store pcalls it and keeps the no-write/decline state for the save and migration rules.
   - The store validates every loaded entry itself: finite curve and axis, boolean locks, and no unknown fields. `versioned-file.parse` guarantees literal-ness only.
   - The store's merge keeps entries for panels that are not live, like `capture.merge`; a save after one panel's commit cannot drop a closed application's or unplugged monitor's properties.
   - The store's merge and identity logic are separate from the file format.
   - The store's toolkit membership is top-level world panels only: skip `presentation == 'attach'` (titlebars), `'dialog'`, and `'follow'`. This keeps transient chrome and locked dialogs out of the store; dialogs have no standard header to unlock.
   - A destroyed panel's entry stays for a later panel of the same name, as placement memory does; it is harmless and needs no pruning.
   - The toolkit side of the store uses `plugin.connectOptional(context, 'desktop/ui-host', uiHost.capability)`; `'desktop/ui-host'` is the child-entry label, not a provider rename, and the capability is `lunette/ui-host`.
     The optional connection has no connect notification, so poll the getter from a `frame:onUpdate` (the plugin already requires `frame.capability`) and subscribe when it changes to a new service, holding the listener effects under `connection.owner`; unsubscribe on outage.
     Read the service getter at use time.
     Add both tests: native properties persist with no `ui-host`, and a store bound before the UI host appears restores/persists toolkit properties once it connects.
2. Identity and slots:
   - Extract one pure `capture.slotOf(held, panels, target)` used by `capture`, `capture.arrived`, and the store: it scans `panels:all()` in order, skips dead panels, and returns the target's ordinal among live same-key monitors (windows use `held:hold`).
     `capture.panelSlot`, `capture`, and `restore` stop threading a counts table.
     Applying an implicit per-call counts table would make every mirror of one key resolve to slot 1.
   - The store's id is `window/appId/slot` or `monitor/key/slot`; toolkit panels use their name.
   - Add a capture-level two-mirror assertion (distinct rendered entries) and a store-level two-mirror test (distinct ids and separate properties).
   - The store's `propertiesOf` adapter builds the value from the panel family's reads.
3. Restore:
   - `panels:onAdded` for native panels and `uiHost:onPanelAdded` for toolkit panels compute the id and apply the saved value without a commit, guarded by `applying`.
   - Also apply stored properties to `panels:all()` at bind for native panels and `uiHost:panels()` for toolkit panels, mirroring the arrangement's live restore, so a provider restart does not leave existing panels on creator defaults. Add a provider-restart test for both families.
   - Only properties the creator omitted are applied; the explicit flags come from the native panel record and the UI host panel-added options.
   - The store's restore does not fire save events; the `applying` guard suppresses its own listeners.
4. Save:
   - Subscribe to `panels:onCurveChanged`, `onLockChanged`, and `onTransformLockChanged`, and to `uiHost:onPropertiesChanged`.
   - On a commit or discrete toggle, update the map and write the file; previews do not save.
   - The app's normal save at quit calls the same store save; a store failure is reported and does not veto quit, matching the drop-save path.
   - The save result names the store's own failure (`panel properties: …`) rather than reusing the arrangement's `arrangement was not saved` message.
5. Migration from the arrangement:
   - The arrangement version 2's input lock is the only property in the old file. On first load, the store reads the version 2 entries' `locked` values, maps them to `PanelId`s, and writes them as `inputLocked`. Curves default to 0 and transform locks to false.
   - Write the store before the arrangement can render version 3. If the store write fails, mark the arrangement save refused so the old v2 file is not replaced before the locks are moved.
   - Migrate only into ids the store lacks (or only when the store file is absent), so a stale surviving v2 file cannot overwrite newer unlocks.
   - The store writes version 1 and the arrangement writes version 3; a version 2 reader refuses the new arrangement as before; the new reader migrates the old one. The store file is unknown to older versions and is never overwritten by them.
   - The store receives the loaded v1/v2 `locked` entries, the `held` slots, and the arrangement's `declined`/save guard from `state.new`; pass them explicitly rather than reaching into the closure.
   - `state:bind` grows the frame service, the optional UI host getter, and the store; update the direct test callers.
   - Test both sequences: a successful migration, and a store write failure that leaves the v2 arrangement untouched.
6. The store's `save`/`restore` participates in the arrangement service:
   - `layout/persistence`'s `save` writes both the arrangement and the store; the store's own save-on-change writes it earlier when possible.
   - The arrangement's `restore` and the store's panel-added restore both run; the store applies properties, the arrangement applies pose/size/tags.
7. Tests: format round-trip, newer-version refusal, identity encode/decode, window/monitor/toolkit restore, save-on-commit/toggle, preview-no-save, explicit precedence, v2 input-lock migration, arrangement v3 refusal by old readers, and store/arrangement coexistence.

### Phase 7: Arrangement version 3

1. `format.luau`:
   - `VERSION = 3`; `Entry` drops `locked` and has no curve/transform fields; it keeps kind, key, slot, pose, width, height, tags.
   - `readEntry` for v1/v2 returns the old `locked` in a migration-only field; v3 has none.
   - `renderEntry` writes the placement fields only; v4 is refused as from the future.
2. `capture.luau`/`state.luau`:
   - `capture` drops the input `locked`; it never had curve or transform fields, so those are new store work rather than a relocation. `answer` returns pose/size/tags only; `apply` applies pose/size/tags.
   - The arrangement no longer saves on lock/curve/transform changes; those move to the properties store. It still saves on drops and at quit.
3. `window/placement` and `rules`:
   - The arrangement answer no longer supplies locked/curve/transform; other rule sources may still set `panels.Options.locked`/`curve`/`transformLocked`.
   - Add `transformLocked` to `lua/lunette-contracts/rules.luau`, `lua/lunette-contracts/schemas/rules.luau`, the rule resolver, and `window/placement/private/service.luau`'s `panelOptions`, so a rule can set it and the creator-explicit precedence applies.
   - The creator-explicit rule decides whether the store fills the property.
4. The migration reads the old v1/v2 `locked` values once for the store; the arrangement v3 file has no lock.
5. Rewrite the existing arrangement tests that assert `.state` write counts on lock toggles: those toggles now write the store, so assert `events.writes == 0` for the arrangement and read `events.files['panel-properties.saved']`.

### Phase 8: Tests

- Shared maths:
  - `curved-surface` unit cases for ray/hit, panel coordinates, frame, half-angle/limit, signed/axis, and zero size.
  - Both native `shape` and UI host `shape` use the shared module; a native/host hit parity case.
- Native panels:
  - Runtime curve raycast for a window and monitor; the case calls `setCurve` after creation so it fails on the current code. The existing shape tests cover creation-time hit geometry; the outline detach is existing behavior with no test, so the new `a curved target detaches the joined outline` case pins it.
  - Layer feature true/false and a fake granted layer's `setCurve`.
  - A widened panel drives the layer with the shared limit, and the fake layer records the clamped curve.
  - `onCurveChanged` preview/commit (same-value commit included).
  - `setTransformLocked` updates the surface and notifies on commit; unchanged skip; owner validation.
  - `a curved target detaches the joined outline`.
- Interaction:
  - `a transform-locked panel refuses grip and trigger grabs while content input still works`.
  - `a two-handed resize of a transform-locked panel is refused`; `rule placement still positions a transform-locked panel`.
  - `a grab in flight ends when the panel is transform-locked`.
  - `an input-locked panel still permits a spatial grab`.
  - `a transform-locked panel leaves its content interactive`: a content press still activates while the grab is refused.
- UI host:
  - Bend/curve composite read/write; half-turn pickability; shared limit case.
  - `an input-locked toolkit panel blocks content but keeps the header and Settings overlay usable`.
  - `a content node on an input-locked panel takes no focus and a focused one is blurred`: `focus.order` excludes content and `setLocked(true)` drops `panel.focused`.
  - `a scroll over locked content does not scroll it, and a trigger press on the locked header still starts a spatial grab`: the scroll bypass and `input.grabs` fallback are pinned.
  - `a content press in flight when the lock engages is cancelled and never activates`.
  - New `ui/host/tests/touch.luau` `a touch press on locked content captures nothing and never activates`.
  - `a transform-locked toolkit panel refuses a grab and resize but its owner can pose and size`.
  - The UI host surface `transformLocked` updates on toggle.
- Standard UI:
  - `the gear and quick locks render as icon buttons`: gear label "Settings"; I/T lock icons; hidden when unavailable; active state; role/traversal.
  - `the Settings popup contains bend, axis, and both locks`: heading; rows; disabled axis reason; toggles.
  - `the Settings menu is absent while closed and after a press outside`: no popup node before opening or after dismissal.
  - `the bend slider bends the panel`; `the axis slider turns the bend`; `a numeric entry sets the bend and the axis keeps the arc`; `an out-of-range numeric entry is clamped on submit`; `a press outside the curve popup closes it`; `closing the popup reverts an uncommitted edit`.
  - `the gear commits on release and toggles on press, and a dismissed preview writes nothing` with a recording controller.
  - `ui/standard/tests/chrome.luau` `a titled panel places the gear and quick locks left of close and after caller actions`, the `propertiesControl = false` case, and the untitled case.
  - Curve conversion/parse/format/zero-size; `ui/standard/tests/standard.luau` `a slider without a heading keeps its accessible name and its track`.
- Decorations:
  - `a window titlebar curves its native panel on commit`, repeated on the monitor; preview does not notify; outline detaches.
  - `the curve control is bend-only for a window`, repeated on the monitor; axis disabled with the reason.
  - `the titlebar follows its target's curve` via a right-edge node pose.
  - `following the target's curve writes no properties entry`: boot the decorations with `desktop/persistence` and assert `events.fileWrites['panel-properties.saved']` stays zero while the titlebar follows; also assert the titlebar's non-committing `setCurve` fires no `onPropertiesChanged`.
  - `the input lock keeps the titlebar and Settings usable`; `the transform lock stops the titlebar drag but not its buttons`.
  - `the old Lock input action is gone`; update the existing lock-action/accessibility cases and add an equivalent retained-callback case for the new properties controller.
- Properties store:
  - `an attached titlebar, dialog, or follow panel receives no properties entry`: the membership filter is what enforces the no-write guarantee; test it directly, including a pre-existing attach/dialog/follow panel skipped during the bind-time enumeration.
  - Store version 1 round-trip, its `fromTheFuture` refusal, identity, window/monitor/toolkit restore, save-on-commit/toggle, `a native commit and a native transform toggle each write panel-properties.saved once`, `a toolkit properties change writes it once`, `a commit writes panel-properties.saved once and a preview writes nothing`, merge preserving absent entries, explicit precedence, migration from arrangement v2, and a raising store write that leaves the v2 arrangement untouched.
  - `two live panels for one monitor key get distinct ids and separate properties`, at the store and capture levels.
  - `native properties persist with no ui-host`; `a store bound before the ui-host appears restores and persists toolkit properties once it connects`.
  - `a provider restart restores native and toolkit properties`; `a quit-time store failure is reported and does not veto quit`.
  - `an overlay panel receives no properties entry`; the handle-bearing exclusion is what enforces it.
- Arrangement:
  - v3 format/round-trip, v1/v2 migration, v4 refusal, state leaves a newer file untouched.
- Keyboard titlebar: no Settings/curve control.
- The manual headset check.

### Phase 9: Documentation

- Contract comments in `vocabulary.luau`, `panel-properties.luau`, `ui-host.luau`, `panels.luau`, `rules.luau`, and `arrangement.luau`; the arrangement comment points at `layout/persistence/private/format.luau` for the version.
- `lua/lunette-contracts/panels-and-ui.md`: the content-only input lock, transform lock, and curved layer/scene guarantees.
- `lua/lunette-plugins/ui/standard/README.md`: icon Button, Settings, quick locks, `showHeading`.
- `lua/lunette-plugins/ui/host/README.md`: content lock, `lockFree`, listeners, and the shared properties value.
- `lua/lunette-plugins/panels/service/README.md`: runtime curve, transform lock, `layerCurve` fallback, shared curved-surface maths, clamped drive.
- `lua/lunette-plugins/panels/decorations/README.md`: Settings, quick locks, titlebar follow, outline detaching, old lock action removal.
- `lua/lunette-plugins/layout/persistence/README.md`: the properties store, identity, migration, arrangement version 3, and the old-writer matrix.
- `lua/lunette-plugins/graphics/README.md`: the shared curved-surface library.
- `docs/users/desktop-configuration.md`: Settings, quick I/T locks, content-only input lock, transform lock including size, persistence, layer/scene fallback, disabled native axis.
- `docs/plugins/ui.md`: the properties controller, quick-lock availability, `propertiesControl`, and the shared store for plugin panels.
- `docs/development/native/rendering.md`: the `layerCurve` capability and scene fallback.
- `docs/development/ui/presentations.md`/`rendering.md`: the Settings above placement, titlebar follow, and content-lock exemption.
- `docs/development/ui/input.md`: the content-only input lock, transform-lock gesture boundary, and shared curved-surface mapping.
- `docs/development/ui/accessibility.md`: icon-only buttons expose state labels and `selected`.
- `docs/development/standard-plugins.md`: the properties store's precedence and the arrangement/properties split.
- Follow `CONTRIBUTING.md`'s documentation policy: one audience per document, guarantees in the contracts/guides, and decisions beside their constraint.

### Phase 10: Validation

- `make check`, plus `cargo test -p lunette --test plugin_dependencies` and `make check-test` explicitly (the shared-module allowlist and the workspace tests).
- Final branch check: `git status --short` is clean, `git branch --show-current` is `feat/panel-properties`, and `git log --oneline <base>..HEAD` shows the per-slice commits. Fix check failures in follow-up commits, not amends.
- Manual headset or `make run`: open Settings on a native titlebar and a toolkit panel; use the gear, I/T locks, toggles, bend/axis; confirm native content lock leaves the titlebar usable and toolkit input lock leaves the header/Settings usable; confirm transform lock stops grip, titlebar drag, and resize while owner placement works; restart and confirm all properties restore; check layer and scene paths and the monitor.

## Acceptance Criteria

- **AC.1** A titled standard Panel shows a gear Settings button left of close, after caller actions, reachable by role and traversal; the I/T lock icons appear left of the gear when available; untitled/`propertiesControl = false` panels show none.
- **AC.2** Settings shows a "Settings" heading, bend/axis rows, and Input lock/Transform lock toggles; the native axis is disabled with its reason.
- **AC.3** Bend/axis sliders and numeric fields apply with conversion, clamp, preview-revert, and dismissal behavior.
- **AC.4** Quick icons and Settings toggles share and reflect input/transform state; the active and accessible states follow a toggle after a step.
- **AC.5** A toolkit input lock refuses content pointer presses and content focus, and a content touch press captures and activates nothing, while the `lockFree` header and Settings overlay remain usable; an in-flight content press is cancelled.
- **AC.6** A native input lock rejects content input while the separate titlebar and Settings remain usable.
- **AC.7** Transform lock refuses grip, titlebar trigger-drag, and two-handed resize including size for native and toolkit panels, while owner `setPose`/`setSize` and rule placement work; an in-flight grab detaches.
- **AC.8** The locks are independent: input lock preserves spatial grabs; transform lock leaves content interactive.
- **AC.9** The titlebar's old Lock input action is removed; the monitor restart/select actions remain.
- **AC.10** Window/monitor runtime curvature maps rays to planar pixels; a curved window uses a cylinder layer only when `layerCurve` is true and otherwise scene geometry; a widened panel drives the layer with the shared clamp.
- **AC.11** The titlebar follows the target's curve; the joined outline detaches when the target curves.
- **AC.12** Window, monitor, and toolkit properties persist in one `panel-properties.saved` keyed by `PanelId`; restore and save-on-commit/toggle work for all three; a preview does not save.
- **AC.13** The arrangement version 3 keeps only placement data; v1/v2 migrate and v4 is refused; the current v2 input lock migrates into the store.
- **AC.14** A creator/rule explicit property wins at creation; the store fills only omitted properties.
- **AC.15** Native and toolkit hit conversion use the shared curved-surface library and agree on a common case.
- **AC.16** The curve conversion, parse, format, zero-size, and half-turn limit cases pass.
- **AC.17** A human confirms the Settings/quick icons, both content locks, transform lock, layer/scene paths, persistence, and the strong-bend axis case on a headset; this is the only real cylinder-submission/visual check.
- **AC.18** The Button icon/active behavior and the Slider `showHeading` behavior pass.
- **AC.19** The work is on `feat/panel-properties`, in coherent per-slice commits with their tests and docs, with no unrelated changes, and the final `make check` passes.
  Verified with `git branch --show-current`, `git log --oneline <base>..HEAD`, `git status --short`, and the final `make check`; the reviewer checks that each commit is a coherent slice.

The Test Strategy maps each criterion to a named test.

## Test Strategy

The Lua harness (`cargo test -p lunette --test lua`) runs the suites; the offscreen graphics harness is not needed because this change adds no shader or mesh.
The native layer needs `events.layerCurve` in `lua/testing/native.luau`; its drive is tested through a fake grant (moved to `panels/service/tests/support/layer.luau`), and only real compositor submission/appearance is manual.
The properties store runs in `layout/persistence` with the fake saved-file map (`events.files[name]`) and the panels/UI host fixtures; the saved-settings harness is not used for properties because the store owns its file. `panel-properties.saved` is a non-`.state` name, so the fake keys it separately from the arrangement.
The UI host content-lock cases drive the real pointer/touch/focus routers; touch uses `poke.step` plus `input.pointer`, because `touch.candidates` alone cannot see the lock.
The popup interactions use a local helper built from `fixture.nodeGeometry(node)` and the runner's `aim`/`button`/`step` (no `dragPopup` exists today); the native titlebar cases use the track kind's `onPreview`/`onFinish` or the same local driver.
The shared maths is unit-tested in `graphics/tests/curved-surface.luau` and through both shape adapters.

### Test-to-AC map

- AC.1: `ui/standard/tests/settings.luau` `the gear and quick locks render as icon buttons`; `ui/standard/tests/chrome.luau` `a titled panel places the gear and quick locks left of close and after caller actions`, the `propertiesControl = false` case, and the untitled case.
- AC.2: `settings.luau` `the Settings popup contains bend, axis, and both locks`, `the Settings menu is absent while closed and after a press outside`.
- AC.3: `ui/standard/tests/curvature.luau`; `ui/standard/tests/chrome.luau` `the bend slider bends the panel`, `the axis slider turns the bend`, `a numeric entry sets the bend and the axis keeps the arc`, `an out-of-range numeric entry is clamped on submit`, `a press outside the curve popup closes it`, and `closing the popup reverts an uncommitted edit`.
- AC.4: `settings.luau` `the quick locks and the Settings toggles share state` and `the gear commits on release and toggles on press, and a dismissed preview writes nothing` (toggle, step, re-read active/semantics).
- AC.5: `ui/host/tests/input.luau` `an input-locked toolkit panel blocks content but keeps the header and Settings overlay usable`, `a content press in flight when the lock engages is cancelled`, `a scroll over locked content does not scroll it, and a trigger press on the locked header still starts a spatial grab`; new `ui/host/tests/touch.luau` `a touch press on locked content captures nothing and never activates`; `ui/host/tests/focus.luau` `a content node on an input-locked panel takes no focus and a focused one is blurred`.
- AC.6: `decorations/tests/controls.luau` `the input lock keeps the titlebar and Settings usable`.
- AC.7: `interaction/pointers/tests/locks.luau` `a transform-locked panel refuses grip and trigger grabs while content input still works`, `a two-handed resize of a transform-locked panel is refused`, `a grab in flight ends when the panel is transform-locked`; `ui/host/tests/input.luau` `a transform-locked toolkit panel refuses a grab and resize but its owner can pose and size`; `window/placement` `rule placement still positions a transform-locked panel`.
- AC.8: `interaction/pointers/tests/locks.luau` `an input-locked panel still permits a spatial grab`, `a transform-locked panel leaves its content interactive`.
- AC.9: `decorations/tests/controls.luau` `the old Lock input action is gone`.
- AC.10: `panels/service/tests/drawing.luau` `a curved window keeps its composition layer only where the headset supports cylinder layers`, `a window widened past the curve limit keeps its layer and hit test on one clamped curve`; `panels/service/tests/panels.luau` `a panel changes its curve at runtime and maps a ray to planar source pixels`; `graphics/tests/curved-surface.luau`.
- AC.11: `decorations/tests/controls.luau` `the titlebar follows its target's curve` and `following the target's curve writes no properties entry`; `panels/service/tests/panels.luau` `a curved target detaches the joined outline`.
- AC.12: `layout/persistence/tests/properties.luau` `a native commit and a native transform toggle each write panel-properties.saved once`, `a toolkit properties change writes it once`, `a commit writes panel-properties.saved once and a preview writes nothing`, `two live panels for one monitor key get distinct ids and separate properties`, `native properties persist with no ui-host`, `a store bound before the ui-host appears restores and persists toolkit properties once it connects`, `a provider restart restores native and toolkit properties`; the per-name `events.fileWrites` counter.
- AC.13: `layout/persistence/tests/format.luau` v3 placement-only, v1/v2 migration, v4 refusal; the store migration case.
- AC.14: `layout/persistence/tests/properties.luau` explicit precedence for native and toolkit.
- AC.15: `graphics/tests/curved-surface.luau`; `panels/service/tests/shape.luau` and `ui/host/tests/shape.luau` shared/parity cases.
- AC.16: `ui/standard/tests/curvature.luau` `bend degrees round-trip through the curve for every axis`, `an axis wraps into the control's range`, `a zero-size panel has no bend`, `the control's limits are the half-turn`, `numeric text parses only inside its range`, `a numeric value formats to one decimal`.
- AC.17: manual headset/`make run`.
- AC.18: `settings.luau` icon/active; `standard.luau` `a slider without a heading keeps its accessible name and its track`.
- AC.19: `git branch --show-current`, `git log --oneline <base>..HEAD`, `git status --short`, and the final `make check`; the implementation reviewer checks the slice boundaries.

## Review Strategy

- Review this plan with `plan_reviewer` before `plan_submit`; fix or rebut all findings and repeat after any critical/high finding.
- After implementation and the Phase 10 checks, dispatch a `general` reviewer against the plan and `CONTRIBUTING.md`, focusing on the one-store identity/migration, the arrangement v3 old-writer matrix, the shared curved-surface parity, the content-lock routing/cancellation, the transform-lock gesture boundary, the icon Button, capability versions, strict Lua annotations, and AC↔test coverage. Fix or rebut every critical/high finding and repeat until none remain.

## Documentation Strategy

Phase 9 lists the contract comments, the UI/panels/graphics/decorations/persistence READMEs, and the user/plugin guides. The user docs state the gear Settings popover, quick I/T locks, content-only input lock, transform lock including size, native vertical-only curvature, toolkit signed/axis curvature, one persistent properties store, and layer/scene fallback. The persistence docs state `panel-properties.saved` version 1, `PanelId`, the arrangement version 3 placement-only shape, the v2 input-lock migration, and the old-writer matrix. The input/accessibility docs state the content/transform boundaries and icon-only button semantics. Follow `CONTRIBUTING.md`'s documentation policy: one audience per document, guarantees in the contracts/guides, and decisions beside their constraint.

## Risks, Blockers, and Required Decisions

- **One properties store, placement stays separate.** The store owns `curve`, `curveAxis`, `inputLocked`, and `transformLocked`; the arrangement owns pose/size/tags and placement memory owns toolkit poses. Merging placement into the store would require a unified panel placement model and is out of scope.
- **The store needs the arrangement's slot identity.** Window application id plus slot and monitor key plus slot come from the existing held-slot logic; the store lives in `layout/persistence` to share it. A future change to slot assignment must update both the arrangement and the store.
- **The arrangement version 3 removes the input lock.** Version 1/v2 readers are handled by the migration; version 2 readers refuse version 3. The new store file is unknown to older versions and is never overwritten by them. The migration is one-time and tested.
- **The content lock is a host input-routing change.** It rejects content pointers, touches, and focus while allowing a `lockFree` header and the Settings overlay. In-flight content presses are cancelled; a future node outside the header must be marked `lockFree` or it will be locked.
- **Transform lock is gesture-only.** Owner placement, rules, and restore still work. Freezing programmatic placement would need an owner/source distinction and a rules bypass.
- **The Settings popup opens above.** The overlay is flat and tangent; opening below would be occluded by a strongly bent panel. The crossed-axis case can tilt the popup past horizontal; the manual AC records the pose.
- **The titlebar follows the target but the joined outline detaches.** The outline is a flat-panel feature; the curved surface and gap carry the chrome.
- **The shared curved-surface refactor is a cross-cutting change.** Both shape adapters and their tests must move together; the native layer and host shader rendering remain separate. The parity test is the safety net.
- **The icon Button is additive.** `icon`/`active` are optional props and kind props are not the service shape, so `lunette/ui-components` stays at version 1.
- **The manual headset check is the only real layer/visual verification.** The store, content lock, transform lock, and shared maths are unit-tested; real cylinder submission and appearance are AC.17.
- **The branch and commits are part of the deliverable.** Create `feat/panel-properties` from a clean tree; do not commit unrelated working-tree changes, and do not push unless asked. If the branch name is already taken, use `feat/panel-properties-2` rather than reusing it. The history is per-slice, not one final squash.
- **The old lock action removal and the new header controls shift existing chrome and traversal.** Update the decorations tests that assert the lock action id/label and the retained-callback list, the standard/plugin-manager/accessibility/wrist-menu cases, and the user docs; add an equivalent retained-callback test for the new properties controller. The full suite is the gate.
- **The persistence assertions change, not just gain cases.** `layout/persistence/tests/format.luau` currently asserts v2 composition/lock round-trips and migration; rewrite those for the placement-only v3 arrangement and put the property round-trip/migration cases in the new store suite.

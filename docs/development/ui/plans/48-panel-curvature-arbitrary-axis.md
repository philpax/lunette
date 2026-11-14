# Native panel curvature: arbitrary axis in the scene path

## Goal

Give window and monitor panels the same curvature model as toolkit panels: a signed curve with a full axis. A native panel that is tilted, signed, or on a headset without cylinder layers renders in the scene with matching hit testing, meshes, outlines, and child surfaces. The composition layer remains the optimisation for an untilted positive curve that the headset supports.

## Implementation Summary

The restriction to a vertical, positive native curve is not a property of the scene path. It comes from three current constraints:

- `Layer:setCurve` has one positive curve and no axis, so a tilted or negative native panel cannot use a composition layer.
- `panels/service/private/shape.luau` builds meshes as vertical strips along the panel x axis and calls `curved.surface(..., 0)` for hits.
- The native panel record, `Options`, rules, store, and decorations controller expose only `curve`.

The change makes the scene path general and the layer the restricted path:

- Native panels gain `curveAxis` and a signed `curve`, with `setCurve(Panel, number, axis?, commit?)` aligned with the toolkit panel signature.
- A native window claims a layer when it is flat (`curve == 0`) whatever its axis, or when it is positive, untilted (`curve > 0`, `curveAxis == 0`), the host reports `layerCurve`, and the rendering mode is `layer`. A negative curve, or a positive curve with a nonzero axis, releases the claim and draws in the scene.
- `curved-surface` gains scalar surface helpers used by both the hit test and the mesh builders, so every vertex and ray goes through the same cylinder.
- Native mesh builders split polygons along the across-axis direction and map every vertex through the shared surface point and normal. Mesh caches include the axis.
- Rules, placement, the properties store, and the native titlebar Settings controller carry the axis, with the curve and axis filled independently from creator or rule values.

### Scope decisions

- **The scene path is general; the layer is the exception.** A tilted or negative native panel always draws in the scene. This is the same fallback already used for `layerCurve = false`, monitors, and windows with child surfaces.
- **Signed native curves are included.** The scene maths already supports them, and leaving native panels positive-only would preserve an arbitrary second restriction. `curved.curvature` keeps the sign and clamps the magnitude at the half-turn limit.
- **Curve axes are normalised to `(-pi, pi]`** at both panel records, native and toolkit, so equivalent angles persist and compare canonically. The toolkit record currently stores the raw angle; this change closes that gap.
- **The `lunette/panels` capability stays at version 6.** Version 6 is introduced by this unmerged branch and has not shipped; the branch's final shape is version 6. If the axis work lands after version 6 ships, it becomes version 7 and the plan must split it.
- **The attached titlebar follows the target's curve and axis as a preview.** Its attached placement still comes from the host's existing target pose and dimensions. Exact chrome alignment on a strongly tilted target is a manual visual check, not a redesign of attach placement in this change.
- **Dialogs, the keyboard titlebar, and overlay panels are unchanged.** They do not use the native titlebar controller or native panels.

### Affected touch points

- `lua/lunette-contracts/panels.luau`: `Options.curveAxis`, `Panel.curveAxis`, `curveAxisExplicit`, signed `setCurve`.
- `lua/lunette-contracts/rules.luau`, `schemas/rules.luau`: `curveAxis` property.
- `lua/lunette-plugins/graphics/curved-surface.luau`: scalar point, bend/panel conversion, axis normalisation.
- `lua/lunette-plugins/panels/service/private/{panel,shape,draw,children,frame}.luau`, `service/init.luau`.
- `lua/lunette-plugins/layout/persistence/private/properties.luau`, `window/placement/private/service.luau`.
- `lua/lunette-plugins/panels/decorations/private/controls.luau`, `init.luau`.
- `lua/lunette-plugins/ui/host/private/{panel,handles}.luau`, `lua/lunette-contracts/ui-host.luau`: toolkit axis normalisation and raw curve/axis actions.
- `lua/lunette-plugins/ui/standard/private/settings.luau`: the raw-value snapshot and controller type.
- Tests under `graphics/tests`, `panels/service/tests`, `layout/persistence/tests`, `window/placement/tests`, `panels/decorations/tests`, and `ui/standard/tests`.
- Documentation listed under Documentation Strategy.

## Implementation Plan

### Phase 1: Shared scalar surface geometry

Add to `lua/lunette-plugins/graphics/curved-surface.luau`:

1. `curved.normalizeAxis(angle)` asserts a finite angle and wraps it into `(-pi, pi]` (`-pi` maps to `pi`). A non-finite axis is a caller error; panel records reject it before calling the helper.
2. `curved.bendOf(surface, u, v) -> (a, b)`: panel coordinates to the bend frame, where `a` is the signed arc length across the axis and `b` is the coordinate along the axis. `a` is the cylinder's local x and `b` its local y; use the existing private `turn`.
3. `curved.panelOf(surface, a, b) -> (u, v)`: the inverse conversion.
4. `curved.point(surface, u, v) -> (x, y, z, nx, ny, nz)`: the panel-frame surface position and the outward unit normal. Derive from the same equations as `curved.frame`:
   - `x = u - width/2`, `y = height/2 - v`, `bx, by = turn(axis, x, y)`.
   - `curve == 0`: `(x, y, 0, 0, 0, 1)`.
   - Otherwise `radius = 1/curve`, `angle = bx * curve`, `px, py = turn(axis, radius*sin(angle), by, back)`, `pz = radius - radius*cos(angle)`, and the normal is `(-cos(axis)*sin(angle), -sin(axis)*sin(angle), cos(angle))`.
5. Keep `curved.frame` unchanged, and add a test that its position and forward direction agree with `curved.point` for flat, positive, negative, and tilted surfaces.

Do not change rendering yet. Tests:

- `curved.point` and `frame` parity for axes `0`, `pi/4`, `pi/2`, curves `0`, `1`, `-1`, and points across the panel.
- `bendOf`/`panelOf` round-trip for the same cases.
- `normalizeAxis`: `0`, `pi`, `-pi`, `pi + 0.1`, `-pi - 0.1`, and a full turn; a NaN or infinite angle raises.
- Flat surfaces ignore the axis and return the plane point and `(0, 0, 1)`.

### Phase 2: Native panel state, hit test, and layer policy

#### Contracts and panel record

In `lua/lunette-contracts/panels.luau`:

- `Options.curveAxis: number?`.
- `PanelFields.curveAxis: number`.
- `PanelFields.curveAxisExplicit: boolean`.
- Change `setCurve` to `(Panel, number, number?, boolean?) -> boolean`: the axis is optional and keeps the current axis when omitted; the commit flag stays last, so native and toolkit calls align.
- Update the comment: a native panel's curve may be signed; a tilted or negative panel renders in the scene.
- Keep capability version 6 and state the rationale in the commit body.

In `lua/lunette-plugins/panels/service/private/panel.luau`:

- `PanelData`: `curveAxis: number`, `curveAxisExplicit: boolean`, `meshCurveAxis: number?`.
- Validate `Options.curveAxis` as finite through `curved.normalizeAxis`; a non-finite axis raises like a non-finite curve.
- `checkCurve` accepts a finite signed number; error text becomes "a finite number".
- `panel.new` stores the normalised `curveAxis` and the explicit flags from `settings.curve` and `settings.curveAxis`.
- `setCurve(_self, curve, axis?, commit?)`: apply `checkCurve`, reject a non-finite supplied axis, keep the current axis when `axis == nil`, normalise the axis, compare both values, skip only an unchanged non-commit, always notify on commit, release any layer claim when either changes.
- `panel.raycast` passes `curveAxis` to `shape.hit`.
- `panel.claim` releases and returns when `kind == 'window'` and (`curve < 0` or (`curve > 0` and (`curveAxis ~= 0` or not `host.layerCurve()`))). A flat window (`curve == 0`) still claims a layer whatever its axis, because the layer is the normal client-content path. Existing child-surface and missing-texture conditions stay.
- `panel.update` drives a layer for `kind == 'window'`, `rendering == 'layer'`, `curve >= 0`, and `(curve == 0 or curveAxis == 0)`. This includes the flat window, which must still receive its viewport and flat curve whatever its axis; the axis has no effect while the surface is flat. Use the shared clamp for the layer curve as today. A negative or curved-and-tilted panel never drives because it never claims.
- `state`/inspection add `curveAxis` and `curveExplicit`/`curveAxisExplicit` were already surfaced; add `curveAxis`.
- `panel.release`/mesh fields: clear `meshCurveAxis` with the mesh.

All existing native `setCurve` callers migrate to the new argument order, because `setCurve(curve, true)` would now pass `true` as the axis:

- `properties.luau` native apply becomes `panel:setCurve(value.curve, value.curveAxis, false)`.
- Native panel tests that pass a commit without an axis become `setCurve(curve, nil, true)`.
- Decorations `controls.luau` and `init.luau` already pass an axis; the toolkit `Panel:setCurve` signature is unchanged.
- UI host and standard Settings callers target toolkit panels and are unchanged.
- Search the tree for `setCurve(` and update every native call before running tests.

#### Hit test

In `lua/lunette-plugins/panels/service/private/shape.luau`:

- `Curved` gains `curveAxis: number`.
- `shape.hit` treats only `curve == 0` as flat; signed curves go through `curved.surface(width, height, curve, axis)` and `curved.ray`, including `backFace`.
- Keep pixel conversion and silhouette polygon checks unchanged.

Tests:

- A runtime native panel is created untilted, then `setCurve(curve, axis, true)`; a ray maps to the expected planar pixel for axes `0`, `pi/4`, and `pi/2` and curves positive and negative.
- The same panel's `commit` notifies once; a preview does not; an unchanged commit still notifies.
- `setCurve` with no axis keeps the current axis; a negative curve is accepted; a NaN or infinite axis and a non-finite curve raise.
- `setCurve(0.5, 5, true)` leaves `panel.curveAxis` at `5 - 2*pi` (and `setCurve(0.5, -pi, ...)` leaves `pi`), and `fromWindow(..., { curveAxis = 3*pi })` stores `pi`: normalisation happens at the record, not only in the helper.
- A layer-configured window claims at axis 0 and positive curve; a flat window (`curve == 0`, any axis) still claims and is driven with a flat layer; setting a nonzero axis on a curved panel releases the claim and draws in the scene; returning the axis to 0 re-claims; a negative curve never claims; `layerCurve = false` never claims.
- Inspect reports the axis.

### Phase 3: Native meshes and caches

Rewrite the mesh builders in `lua/lunette-plugins/panels/service/private/shape.luau` around the shared surface helpers.

#### Generic polygon mapping

Add one internal mapper, used by `arc`, `rounded`, `mapTriangles`, and child content:

1. Convert each source point `(x, y)` (panel coordinates, y down) to bend coordinates `(a, b)` with `curved.bendOf`.
2. Compute the polygon's own `a` and `b` ranges. Strip the polygon along `a` into `SEGMENTS` strips over `[minA, maxA]`; a flat surface uses one strip. Do not clamp the strip span to the panel's across-extent: an outline ring reaches beyond the panel by its thickness, and at a tilted axis its corner's `a` exceeds `across/2 + thickness`. Deriving the span from the polygon keeps the ring's outer corners.
3. For each strip, clip the bend-space polygon with `geometry.clip`. The ring already carries its thickness, so no separate expansion is added; `shape.mapTriangles` drops its `expansion` parameter and its callers stop passing thickness (the ring's outer perimeter supplies it).
4. Triangulate each clipped polygon with `geometry.triangles`.
5. For each point, map `(a, b)` to `(u, v)` with `curved.panelOf`, then to position and normal with `curved.point`. Texture coordinates are `u/width`, `v/height`.
6. Emit `{ x, y, z, nx, ny, nz, u, v }` in the existing mesh format, reversing each triangle's second and third indices so source y-down faces map to native y-up faces.
7. Use the clamped curve from `curved.curvature` for all mapping and strip extents; one clamp serves the hit, the mesh, and the layer.

API changes:

- `shape.halfAngle(width, height, axis, curve)` uses `curved.across`.
- `shape.arc(width, height, curve, axis, segments)`: build the source rectangle polygon and call the mapper, so a tilted or signed rectangle follows the cylinder.
- `shape.rounded(width, height, curve, axis, polygon)`.
- `shape.mapTriangles(width, height, curve, axis, points, triangles)`.
- Remove the old vertical `appendPolygon` and the x-only strip logic. Update every `halfAngle`/`arc`/`rounded`/`mapTriangles` call site (`draw.luau`, `children.luau`, `panels/service/tests/shape.luau`) in the same phase.

#### Draw and child caches

- `draw.luau`: `Drawable.curveAxis`; mesh key includes `target.curveAxis`; `meshCurveAxis` is compared and stored; the outline cache gains `curveAxis`; mesh conditions use `curve ~= 0` rather than `curve > 0`; the scene plane path is unchanged for flat panels.
- `children.luau`: `Target.curveAxis`; the child mesh key includes the axis; pass the axis to `shape.rounded`.
- `frame.luau`: joining stays flat-only (`curve == 0`); the axis does not matter on a flat panel. A tilted curved target detaches the outline as a curved target does today.

Tests:

- `shape.arc`, `shape.rounded`, and `shape.mapTriangles` for axes `0`, `pi/4`, `pi/2`, and negative curves: every vertex position and normal agrees with `curved.frame`/`curved.point` at its texture coordinates; every triangle's winding agrees with its vertex normals.
- A tilted outline keeps its outer ring: the generated mesh's `a` range covers the ring polygon's `a` range (including the thickness), and a 45-degree outline has the same vertex/triangle coverage as the flat one, so corner clipping cannot pass silently.
- Flat meshes still map to the plane and keep the existing UV endpoints.
- A tilted panel past the half-turn limit uses the shared clamp and wraps once.
- Native and toolkit hit parity remains: the native shape's pixel conversion of a shared hit equals the toolkit's metres for a tilted axis as well as vertical.
- The drawing test: a layer-configured window with a nonzero axis draws scene content and holds no claim; a vertical positive window still claims; a negative window draws scene content.
- Child content and outline meshes rebuild when only the axis changes.

### Phase 4: Creator, rule, and store axis

In `lua/lunette-contracts/rules.luau`, `schemas/rules.luau`, and `window/placement/private/service.luau`:

- Add `curveAxis` to `Properties`, `Resolved`, `propertyKinds` (number), and `panelOptions`.
- Creator/rule precedence treats curve and axis independently.

In `lua/lunette-plugins/layout/persistence/private/properties.luau`:

- `recordNative` stores `panel.curveAxis` instead of `0`.
- The loaded-entry validator normalises a finite axis with `curved.normalizeAxis`, so a stale or foreign file with an equivalent angle is rewritten canonically on the next save. A non-finite axis is already refused.
- `applyNative` preserves an explicit curve or axis and fills the other:
  ```
  curve = if panel.curveExplicit then panel.curve else value.curve
  axis = if panel.curveAxisExplicit then panel.curveAxis else value.curveAxis
  if not (panel.curveExplicit and panel.curveAxisExplicit) then
    panel:setCurve(curve, axis, false)
  end
  ```
- `applyToolkit` does the same with `options.curve`, `options.curveAxis`, and `handle:curve()`/`handle:curveAxis()`.
- The migration defaults remain `curve = 0, curveAxis = 0`; the store format stays version 1 because the field already exists.

Tests:

- Native and toolkit restore/save a nonzero axis; two mirrors keep separate axes; a stored axis of `5` restores as `5 - 2*pi` and saves canonically.
- A creator curve with a stored axis keeps the creator curve and takes the stored axis; a creator axis with a stored curve keeps the creator axis and takes the stored curve; both explicit wins entirely.
- A rule `curveAxis` initializes a panel and placement still poses it.
- Migration from v2 writes axis 0.
- The store's round-trip includes the axis.

### Phase 5: Toolkit raw reads and native titlebar Settings

Before the titlebar controller, expose the raw toolkit values and normalise its axis:

- `lua/lunette-contracts/ui-host.luau`: `Actions` gains `curve: () -> number` and `curveAxis: () -> number`, documented as the stored values before any half-turn clamp. The UI host capability stays at version 2 because version 2 is unshipped on this branch.
- `lua/lunette-plugins/ui/host/private/handles.luau`: `handles.actions` reads `panel.curve` and `panel.curveAxis`.
- `lua/lunette-plugins/ui/host/private/panel.luau`: `bend` normalises the axis with `curved.normalizeAxis` after asserting it is finite, so toolkit creation and `setCurve` store canonical angles like the native record.
- `ui/standard/private/settings.luau`: `settings.Controller` gains optional `raw: (() -> { curve: number, axis: number })?`; `settings.checked` validates it when present; `ownPanel` supplies it from `act.curve`/`act.curveAxis`. `open()` seeds the committed values from `raw()` when present, otherwise from `bend()` for a custom controller that predates or omits it.
- `ui/standard/tests/settings.luau`: assert opening and closing an over-limit panel restores the raw curve/axis, and that a commit of the displayed clamped value lowers the stored curve. `ui/host/tests/panel.luau`: assert a toolkit axis of `5` normalises to `5 - 2*pi`.

In `lua/lunette-plugins/panels/decorations/private/controls.luau`:

- `Properties.axis = true`, `negative = true`, `axisReason = nil`.
- `bend()` returns `axis = panel.curveAxis` and clamps with `curved.curvature(width, height, panel.curve, panel.curveAxis)`, so the Settings read-out derives its degrees from the same across-axis extent the panel uses. Calling `curvature.curve` with a different axis would rewrite a clamped curve.
- `raw()` returns `{ curve = panel.curve, axis = panel.curveAxis }`, the unclamped stored values.
- `settings.Controller` and `controls.Properties` both carry optional `raw`; the native and own-panel controllers return it, and the standard Settings falls back to `bend()` for a controller that omits it.
- `setCurve(curve, axis, commit)` calls `panel:setCurve(curve, axis, commit == true)`.
- The `AXIS_REASON` constant is removed.

The standard `Controller` uses the raw values, when supplied, so dismissing an untouched popup restores exactly what was stored, including a curve above the half-turn limit. `open()` seeds `committedCurve`/`committedAxis` from `raw()` and falls back to `bend()` otherwise, while the slider display still reads `bend()`. `close()` previews the committed values. A commit from the displayed clamped value writes the curve that produces that arc and may lower an over-limit stored curve; that is allowed and documented. The toolkit `ownPanel` controller reads raw values from the new `Actions.curve()`/`Actions.curveAxis()` methods; the native controller reads the target fields. A `Bend` field is `axis`, not `curveAxis`.

In `lua/lunette-plugins/panels/decorations/init.luau`:

- The titlebar follows both values: `current.panel:setCurve(target.curve, target.curveAxis, false)`.
- The attached chrome and joined-outline rules are unchanged; the outline detaches for any curved target.

Tests:

- A window and a monitor titlebar Settings turn the native panel's axis; the native panel's `curveAxis` changes and a commit saves the store once.
- Opening and closing Settings on an over-limit tilted panel leaves the stored `curve` and `curveAxis` untouched. This pins the raw-value snapshot.
- A tilted panel's read-out uses the panel's axis: a stored curve of `1`, axis `pi/4`, and width and height `2` displays the degrees derived from `bend.axis`, not from axis 0. This pins that `bend()` reports `panel.curveAxis`; it does not by itself pin the clamp argument.
- The clamp itself is pinned directly: with width and height `2`, axis `pi/4`, and a stored curve of `4`, `properties.bend().curve` equals `curved.curvature(2, 2, 4, pi/4)` (about `2.221`), not the width-only `pi`. A display assertion cannot distinguish these because both read `180` after the control clamp.
- A commit of the displayed clamped value may lower an over-limit stored curve to the drawn limit, and a test states that.
- A toolkit panel's axis is normalised at the record as well, not only when the store reloads it.
- The axis row is enabled for native, has no disabled reason, and the bend allows a negative value.
- The titlebar's own curve and axis follow the target as a preview and write no properties entry.
- The existing input/transform lock, close, and drag tests still pass.
- A manual check records the attached titlebar's visual alignment on a tilted target.

### Phase 6: Documentation and final validation

Documentation is listed under Documentation Strategy.

Run `make check-luau`, `make check-luau-annotations`, `make check-format`, `make check-definitions`, `cargo test -p lunette --test plugin_dependencies`, all Lua suites, `cargo clippy --workspace --all-targets -- -D warnings` for both feature sets, and the `make check` targets. The graphics and benchmark targets need the explicit Mesa lavapipe `VK_DRIVER_FILES`, as recorded in the build guide. The headset check remains manual.

### Version control

Work on a branch from the current `feat/panel-properties` or a new branch from it, never on `main`. Commit per phase with the tests and docs for that phase:

1. `Add shared surface point and axis helpers`
2. `Render tilted native panels in the scene`
3. `Store native panel curve axes`
4. `Offer the axis on native titlebars`
5. `Document native panel axes`

Intermediate commits must leave their targeted tests green. Do not amend or force-push.

## Acceptance Criteria

- **AC.1** A native panel exposes `curveAxis`, accepts a signed curve and a finite axis through `setCurve`, refuses a non-finite curve or axis, normalises the axis to `(-pi, pi]` at creation and at `setCurve`, keeps the axis when omitted, notifies on commit, and stays silent for a preview.
- **AC.2** A ray against a tilted native window or monitor maps to the same planar pixel as the shared closed-form conversion for axes `0`, `pi/4`, and `pi/2`, and for positive and negative curves.
- **AC.3** A native window or monitor draws in the scene whenever its curve is tilted, negative, or unsupported by `layerCurve`; an untilted positive curve still claims a layer where supported. A flat window keeps its layer and is driven with a flat curve, whatever its axis.
- **AC.4** Native content, outline, and child meshes for a tilted or signed panel lie on the shared cylinder, carry matching normals and winding, clamp at the half-turn limit, and rebuild when only the axis changes.
- **AC.5** A native titlebar's Settings control offers the axis and a negative bend; its titlebar follows the target's curve and axis without a properties commit.
- **AC.6** The properties store saves and restores a native axis; a creator or rule curve and axis each win independently, and the other is filled from the store.
- **AC.7** Rules and placement can set `curveAxis`, and rule placement still poses the panel.
- **AC.8** The shared `point`, `bendOf`, `panelOf`, and `normalizeAxis` helpers agree with the existing frame maths.
- **AC.9** The existing input lock, transform lock, sticky Settings popup, and quick unlocks remain unchanged.
- **AC.10** Documentation states that native panels take a signed curve and axis in the scene, that the layer is limited to an untilted positive curve, and that the attached titlebar's alignment on a strongly tilted target is visually checked.
- **AC.11** Opening and closing Settings without committing leaves the stored raw curve and axis untouched for native and toolkit panels, including a curve above the half-turn limit; committing the displayed clamped value may lower the stored curve; both panel records normalise their axis.

## Test Strategy

Named tests and their criteria:

- AC.1 → `panels/service/tests/panels.luau`: `a panel takes a signed curve and an axis at runtime, and only a commit notifies`; `setCurve without an axis keeps the current axis`; `a non-finite curve or axis is refused`; `a native curve axis normalises at the record`.
- AC.2 → `panels/service/tests/shape.luau`: `a tilted native panel maps a ray to the expected planar pixel`; `a signed native panel maps a ray through the shared surface`; `graphics/tests/shape-parity.luau` extended with tilted cases.
- AC.3 → `panels/service/tests/drawing.luau`: `a tilted or signed window draws in the scene and releases its layer`; `an untilted positive window keeps its layer`; `a flat window keeps and drives its layer whatever its axis`; `a window returns to the layer when its axis returns to zero`.
- AC.4 → `panels/service/tests/shape.luau`: `tilted and signed arc, rounded, and outline vertices lie on the shared cylinder`; `triangle winding agrees with vertex normals`; `a tilted outline keeps its outer ring`; `a tilted panel past the half-turn limit wraps once`; `drawing.luau`: `only the axis rebuilds content, outline, and child meshes`.
- AC.5 → `panels/decorations/tests/controls.luau`: `a window and monitor titlebar turn the target axis`; `a tilted panel's read-out uses the panel's axis`; `a tilted controller clamps with the across-axis extent`; `opening and closing Settings on an over-limit tilted panel leaves the stored curve and axis untouched`; `the native titlebar follows the target curve and axis without writing properties`; update the old axis-disabled case to the enabled case.
- AC.5/AC.1 toolkit normalization → `ui/host/tests/panel.luau`: `a toolkit panel normalises its curve axis`.
- AC.6 → `layout/persistence/tests/properties.luau`: `a native axis restores and saves`; `a creator curve keeps a stored axis`; `a creator axis keeps a stored curve`; `both explicit wins`; equivalent toolkit cases.
- AC.7 → `window/placement/tests/placement.luau`: `a rule curve axis initializes a panel and placement still poses it`.
- AC.8 → `graphics/tests/curved-surface.luau`: `point and frame agree for flat, signed, and tilted surfaces`; `bend and panel coordinates round-trip`; `the axis normalises into the control range`.
- AC.9 → existing suites: `interaction/pointers/tests/locks.luau`, `ui/host/tests/input.luau`, `ui/host/tests/focus.luau`, `ui/standard/tests/settings.luau` (sticky popup), `panels/service/tests/panels.luau` (vertical lock/curve).
- AC.11 → `ui/standard/tests/settings.luau`: `opening and closing an over-limit panel preserves the raw curve`; `committing the displayed bend lowers the stored curve to the limit`; `ui/host/tests/panel.luau`: `a toolkit panel normalises its curve axis`; `panels/decorations/tests/controls.luau`: the native counterpart of the raw preservation case.
- AC.10 → manual review of the documentation diff; the titlebar alignment is part of the manual headset check.

Property-based tests: the shared maths cases use a deterministic fixed sample and the frame oracle. Mesh checks assert a geometric property (on the cylinder and normal/winding agreement) rather than restating `curved.point`.

Manual check: on a headset or `make run`, open Settings on a window and a monitor, tilt the axis with a positive and a negative bend, confirm the scene path, hit targets, content, outline, and titlebar; confirm the layer path at axis 0 where supported; confirm a `layerCurve = false` fallback; confirm persistence across restart. Record that a strongly tilted titlebar's attached alignment is approximate.

## Review Strategy

Before `plan_submit`, run `plan_reviewer` against this file and the current branch, focusing on the mesh tessellation, the layer fallback conditions, signed-curve scope, store precedence, capability version, and test coverage. Fix or rebut every critical and high finding and repeat until none remain.

After implementation, dispatch a `general` reviewer against this plan and `CONTRIBUTING.md`, focusing on:

- the scene/layer boundary and cache invalidation;
- the generic mesh mapper's winding, normals, clipping, and half-turn clamp;
- independent curve/axis precedence in the store;
- native/toolkit signature and capability consistency;
- the titlebar follow and attach interaction;
- acceptance-criterion test coverage.

Fix or rebut every critical/high finding and repeat until none remain.

## Documentation Strategy

- `lua/lunette-plugins/graphics/README.md`: the scalar surface helpers and axis normalization.
- `lua/lunette-plugins/panels/service/README.md`: native signed curve and axis, scene fallback, layer limits, mesh cache invalidation.
- `lua/lunette-plugins/panels/decorations/README.md`: native Settings axis and titlebar follow.
- `lua/lunette-contracts/panels-and-ui.md`: native scene/layer guarantee and hit/mesh parity.
- `lua/lunette-contracts/panels.luau`, `rules.luau`, `arrangement.luau` comments as needed.
- `docs/users/desktop-configuration.md`: native bend and axis, layer/scene fallback, persisted axis.
- `docs/plugins/ui.md`: native titlebar controller axis availability.
- `docs/development/native/rendering.md`: `layerCurve`, tilted/signed scene fallback, and the shared clamp.
- `docs/development/ui/presentations.md`/`rendering.md`: titlebar follow on tilt and the attach-alignment limitation.
- `docs/development/standard-plugins.md`: curve and axis precedence in the properties store.

Follow `CONTRIBUTING.md`: guarantees in the contracts and guides, decisions beside the constraint, no second copy of signatures or defaults.

## Risks, Blockers, and Required Decisions

- **Mesh correctness is the main risk.** Tilted and signed mapping changes every native mesh vertex. The frame oracle, cylinder-distance, normal/winding, and cache tests are the safety net; appearance still needs the manual headset pass.
- **Attached titlebar alignment on a tilted target is approximate.** The titlebar's own curve and axis follow, but the attach placement uses the target pose and dimensions. If the manual check shows unacceptable chrome, a follow-up must place the titlebar on the target's top edge frame rather than change this plan mid-flight.
- **The layer switch can flicker at axis 0 / nonzero boundaries** as a preview crosses. This is the existing layer/scene fallback; the axis check only adds another reason to release. No fix is required, but it should be noted in the manual check.
- **The layer gate must include flat windows.** Gating the drive on `curve > 0` would leave `granted` false for the default flat window while its claim exists. The drive gate is `curve >= 0 and (curve == 0 or curveAxis == 0)`; the claim guard excludes only negative and curved-and-tilted panels.
- **Capability version 6.** The branch is unmerged; keeping 6 avoids a meaningless bump. If the axis work lands separately after 6 ships, bump to 7 and split the change.
- **Signed native curves change existing tests** that assert a negative native curve is refused (`panels/service/tests/panels.luau`). Update them to the new policy; do not keep a dead negative rejection.
- **Store format stays version 1.** `curveAxis` is already a field; old entries carry `0`. No format migration is needed. If a future reader treats a missing axis as non-zero, that is a separate format change.
- **Titlebar Settings popup remains sticky.** The axis work must not regress the `sticky` portal behaviour; the existing pose test stays.
- **No dependency or generator changes are expected.** `make check-definitions` should stay clean.

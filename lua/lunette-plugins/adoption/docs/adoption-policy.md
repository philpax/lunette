# Adoption policy

The adoption provider exposes a service that starts window adoption for an owner. The shipped `desktop/adoption` consumer starts that service, passes its configured filter and default tags, and adds pose memory as an optional child.

## Eligibility and placement

A start subscribes to `lunette.onWindowOpened` and examines windows already present. It ignores dead windows and windows that already have a panel. The configured filter runs before rule resolution. A resolved `adopt = false` excludes the window; when the rule leaves `adopt` unset, the start's `defaults.adopt` value can exclude it. Otherwise placement receives the resolved properties and defaults. The shipped consumer supplies its configured tags as defaults and does not set an `adopt` default.

A placement created by the start belongs to the start owner's lifetime. Ending the start unsubscribes and disposes its placements. The provider does not close the underlying windows. The adoption contract in [adoption.luau](../../../lunette-contracts/adoption.luau) defines the service and filter shape. The [placement contract](../../../lunette-contracts/placement.luau) defines placement results and ownership.

## Pose memory

The optional pose-memory child registers a `lunette.pose` rule source at `PRECEDENCE.native` before the adoption consumer starts. On a drop, it stores the panel pose as the window's `lunette.pose` property. On later resolution, that property supplies the pose and overrides the saved arrangement's lower precedence. The child requires `lunette/drops`, `lunette/panels`, and `lunette/rules`; it does not require the interaction provider. A replacement interaction implementation that enables pose memory must emit drops through the drops contract.

The pose property stores an encoded sixteen-number matrix. The neutral vocabulary in [vocabulary.luau](../../../lunette-contracts/vocabulary.luau) owns encoding, decoding, and named rule-source precedences. A malformed encoded pose is ignored by placement and reported.

## Decisions

Placement is composed from separate entries so a configuration can replace adoption without copying rules, layout, or persistence policy. Pose memory remains one child that writes a dropped pose and registers the source that reads it. Splitting those operations would lose hand-placed poses across reloads. A provider method for the reading half was rejected because a replacement adoption provider would then carry only half of the feature.

The child starts before the first window resolves. This registers the source before adoption. Arrangement exclusions and the reason a dropped panel stays excluded belong to the separately maintained [desktop arrangement policy](../../desktop/arrange/README.md).

## Known gaps

Shared input and drop limitations remain in [Input](../../../../docs/dev/input.md#known-gaps) and the [Lua API](../../../../docs/dev/lua-api.md#pointers-and-drops). The adoption provider adds no separate acceptance claim.
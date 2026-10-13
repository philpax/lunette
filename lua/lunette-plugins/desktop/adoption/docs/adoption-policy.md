# Adoption policy

The `lunette/adoption` provider exposes an owner-scoped `start` operation. The desktop consumer starts it with configured default tags and a filter callback. The provider does not close windows. Disposing a start releases its subscription and placements without closing the windows.

## Window discovery and placement

Each start subscribes to window-open events before enumerating the windows already present. This ordering covers a window opened during startup without missing a window that was already registered. For each window, the provider skips dead windows, windows that already have a panel, and windows rejected by the optional filter. The filter receives the window handle.

The provider resolves the window's rules first. An explicit resolved `adopt = false` prevents adoption. If the rule does not set `adopt`, the provider uses the start's defaults. It passes the resolved properties and defaults to the placement service, which creates the panel and tags. The desktop consumer supplies `tags` as the start defaults. The schema and callback default are in [`config.luau`](../config.luau); the provider implementation is [`lua/lunette-plugins/adoption/service.luau`](../../../adoption/service.luau).

Each start owns the placements it creates. When that start ends, it unsubscribes and disposes those placements in acquisition order. It attempts every disposal and raises the first failure after the remaining releases have run. It does not close the windows. If another owner destroys a panel first, the provider prunes the dead adoption record rather than releasing an already-ended placement.

## Pose memory child

The optional child listens for drops, reads the dropped window panel's current pose, encodes it, and writes it to the window's `lunette.pose` property. It also registers the `lunette.pose` rule source at native precedence. When rules resolve the window on a later adoption, the source returns the stored pose.

The child must start before the adoption entry resolves its first window. That ordering ensures the native rule source can answer the first placement. The child requires rules, drops, and panels. A failure or outage in this child leaves the parent adoption service running, but hand-placed poses are not recorded or restored through this feature while the child is inactive.

The full source precedence and saved-arrangement rules are shared with the default rules and persistence consumers in [Standard plugins](../../../../../docs/dev/standard-plugins.md#placement). The rules contract and pose encoding vocabulary remain authoritative for the data shape.

## Decisions

Pose memory writes on a drop and registers the source that reads the pose. Either half without the other loses hand-placed poses across reloads. A provider method for the reading half was rejected because a substitute adoption provider would carry half a feature. The child belongs to `desktop/adoption` and starts before adoption resolves the first window, so its source is registered in time.

## Known gaps

The adoption service's inspection snapshot reports that filter results require callbacks. Inspection does not run those callbacks. The shared adoption, placement, rules, and saved-arrangement behavior remains in [Standard plugins](../../../../../docs/dev/standard-plugins.md#placement).

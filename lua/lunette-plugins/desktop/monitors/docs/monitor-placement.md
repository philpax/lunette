# Monitor placement

`desktop/monitors` creates a panel for each selected monitor and assigns it a place in a row. The consumer listens for monitor additions and mirrors the monitors present when it activates. Present monitors are sorted by name before placement. A monitor whose name is not in a non-empty `select` list is ignored; an empty list selects every monitor.

The first mirror uses the configured center. Later mirrors alternate outward from the center, starting to the right: places 1, 2, 3, and 4 offset by +1, -1, +2, and -2 width-plus-gap intervals. When a mirror is removed, its place becomes free. A later monitor uses the lowest free place. Existing mirrors are not re-laid when another monitor arrives or disappears, because saved arrangement restores a mirror as it appears.

The defaults and validation for selection, center, width, gap, and tags are defined in [`config.luau`](../config.luau). The panels contract owns monitor panel lifecycle. Capture and portal workflows remain in [Monitors and titlebars](../../../../../docs/guide/desktop-configuration.md#monitors-and-titlebars).

## Tagging child

When `tags` is non-empty, a child requires `lunette/tags` and adds each mirror to configured tags that exist. It listens for configured tags created later and adds every current mirror to them. A missing tags provider therefore disables tagging but leaves mirroring active.

## Decisions

Mirrors use the lowest free place and are not re-laid when the set changes, because the saved arrangement restores a monitor panel as it appears. Default composition, monitor capture, and persistence are separate concerns; see [Standard plugins](../../../../../docs/dev/standard-plugins.md#default-configuration) and [Placement](../../../../../docs/dev/standard-plugins.md#placement).

## Known gaps

Portal capture and permission are host workflows, not mirror-placement behavior. [Desktop configuration](../../../../../docs/guide/desktop-configuration.md#monitors-and-titlebars) records the portal workflow and existing-mirror behavior when sharing stops.

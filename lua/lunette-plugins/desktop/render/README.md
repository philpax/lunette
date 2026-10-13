# Panel rendering

`@lunette-plugins/desktop/render` updates and draws registered panels in the `scene` phase. The shipped desktop uses entry `desktop/render`.

The entry requires `lunette/frame` and `lunette/panels`. Its optional `surfaces` child requires `lunette/panels` and `lunette/surfaces`; it offers shown panels for pointer picking. A surfaces-provider outage therefore stops pointing at panels without stopping panel drawing. The entry has no configuration fields. Its source of truth is [`init.luau`](init.luau).

The panels provider owns geometry, rendering mode, and resource behavior. [Window rendering](../../../../docs/guide/desktop-configuration.md#window-rendering) is the configuration workflow; shared renderer guarantees remain in [Rendering](../../../../docs/dev/rendering.md). Rendering, mirroring, and the hint are separate entries, so a configuration can replace one without replacing the others. Offering panels is a child of this entry and requires `lunette/surfaces`, so a surfaces outage stops pointing while panels continue drawing. Monitor mirrors take the lowest free place in their row and are not re-laid, because saved arrangement restores a mirror as it appears. Default composition stays in [Standard plugins](../../../../docs/dev/standard-plugins.md#default-configuration).

## Known gaps

A surfaces outage stops panel picking while panels continue drawing. Shared rendering and geometry limits remain in [Rendering](../../../../docs/dev/rendering.md).

# Window arrangement

`@lunette-plugins/desktop/arrange` arranges live window placements that have no pose, grouped by tag. The shipped desktop uses entry `desktop/arrange`. Its definition is a factory so its dropped-panel exclusions can survive activations within a runtime.

The entry requires `lunette/drops`, `lunette/frame`, `lunette/layouts`, `lunette/panels`, `lunette/placement`, and `lunette/tags`. [`config.luau`](config.luau) is the source of truth for `layout` and `tags`; the default layout name is `arc`, and an empty tag list means all tags. A configuration can register another named layout with the layouts broker, then select its name here.

[Arrangement policy](docs/arrangement-policy.md) specifies candidate selection, tag ordering, reapplication, and missing-layout reporting. Shared layout registration semantics are in [`layout-registration.md`](../../layouts/docs/layout-registration.md) and [The Lua API](../../../../docs/dev/lua-api.md#bindings-menu-actions-and-layouts). Default composition and rule precedence remain central in [Standard plugins](../../../../docs/dev/standard-plugins.md#placement). Tests: [`arrange.luau`](tests/arrange.luau).

The arc is the only shipped layout. [`examples/layout`](../../../../examples/layout) holds grid and follow layouts as examples. See [Arrangement policy](docs/arrangement-policy.md#known-gaps).

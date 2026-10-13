# Window adoption

`@lunette-plugins/desktop/adoption` starts adoption for eligible windows as placed panels. The shipped desktop uses entry `desktop/adoption`.

The entry requires `lunette/adoption`. Its `pose-memory` child requires `lunette/rules`, `lunette/drops`, and `lunette/panels`; the child records dropped poses and registers the rule source that restores them. The child is separate, so its provider outage does not stop adoption. [`config.luau`](config.luau) is the source of truth for `tags` and the `filter` callback. The callback receives a window and defaults to accepting it.

Use the `filter` callback to exclude windows and `tags` to name default placement tags. [Adoption policy](docs/adoption-policy.md) specifies the child behavior and its ordering. The placement contract owns resolution and panel creation; see [Rules and placement](../../../../docs/dev/lua-api.md#rules-and-placement). The shipped default composition remains in [`lua/lunette-desktop/init.luau`](../../../lunette-desktop/init.luau). Tests: [`pose-memory.luau`](tests/pose-memory.luau).

The pose-memory child and its rationale are specified in [Adoption policy](docs/adoption-policy.md). The complete shared placement ordering remains in [Standard plugins](../../../../docs/dev/standard-plugins.md#placement).

## Known gaps

Placement source precedence and saved-state behavior are shared with the default rules, persistence, and arrangement entries. Their combined contract and failure behavior remain in [Placement](../../../../docs/dev/standard-plugins.md#placement).

# Default window rules

`@lunette-plugins/desktop/rules` registers the shipped rule list with the `lunette/rules` service. The desktop entry id is `desktop/rules`.

The entry requires `lunette/rules`. [`config.luau`](config.luau) is the source of truth for the rule schema and defaults. The default rule matches Firefox by `appId`, gives it width 2, and places it at `(-1.4, 1.5, -1.2)` with a 0.9-radian rotation about the y axis. A configured `rules` list replaces that default list. Use the rules contract to add other sources rather than editing this consumer.

[Placement precedence and composition](../../../../docs/dev/standard-plugins.md#placement) specifies how this source combines with persisted and native poses. The rules contract owns match and property types. Tests: [`schema-validation.luau`](tests/schema-validation.luau).

## Decisions

The default rules are a separately replaceable source. Shared rule precedence and placement resolution remain in [Standard plugins](../../../../docs/dev/standard-plugins.md#placement).

# Rule resolution

The rules provider combines owner-scoped rule sources into resolved properties. The service contract in [rules.luau](../../../lunette-contracts/rules.luau) defines the shared API and precedence rule. This page records the built-in matching, validation, and desktop rule-list policy.

## Matching and properties

A rule may omit `match`, in which case it matches every window. Supported match fields are `dead`, `id`, `title`, `appId`, `width`, `height`, `opaque`, `contentType`, and `where`. A field can be a literal of its declared type or a predicate receiving the field value and the window. `where` receives the window. `contentType` accepts `none`, `photo`, `video`, or `game`.

Supported named properties are `pose`, `width`, `height`, `title`, `priority`, `chrome`, `curve`, `hidden`, `adopt`, and `tags`. A function under one of those property names is evaluated with the window and property name. A function under another property key is a literal value. Unknown string property keys pass through the resolved result for consumers that define additional properties. Match fields and rule properties must be plain tables without metatables. Tags must be a list of strings.

Rules resolve in source precedence order, then registration order for sources at the same precedence. Rules within one rule set are applied in list order. Later values replace earlier values for the same key. Function-valued named properties are evaluated after sources merge. A resolver's output is validated when it answers. Resolution walks a snapshot of the registered sources, so a source that changes registrations does not change the active walk.

## Shipped rule list

`desktop/rules` registers its configured rules through `rules:setRules`. Its schema in [desktop/rules/config.luau](../../desktop/rules/config.luau) owns the rule-list shape and default. The shipped default sizes and places Firefox. The rule provider's schema in [config.luau](../config.luau) owns the default source precedence. Each schema is the source of truth for configuration values.

## Decisions

Rules sources are separate from placement. Placement depends on rules, panels, and tags, while rule resolution does not require a panel implementation. Plugin-specific placement behavior therefore remains outside this provider.

Unknown match fields and malformed rule tables are rejected rather than ignored. Property fields outside the named set pass through because they can carry consumer-specific data; the placement provider maps known panel options and preserves the other resolved properties for consumers.

Shared source ordering and provider-binding guarantees are specified in [the Lua API](../../../../docs/dev/lua-api.md#rules-and-placement) and [the plugin runtime](../../../../docs/dev/architecture.md#plugin-runtime). The contract owns the service shape; this plugin page does not redefine the runtime graph.
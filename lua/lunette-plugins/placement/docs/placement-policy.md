# Placement policy

The placement provider is the integration component between rules, panels, and tags. The shared service shape and lifecycle contract are specified in [the Lua API](../../../../docs/dev/lua-api.md#rules-and-placement) and [placement.luau](../../../../lua/lunette-contracts/placement.luau).

## Placement composition

Placement is `desktop/workspaces`, `desktop/rules`, `desktop/persistence`, `desktop/arrange`, and `desktop/adoption`. The placement provider joins rules, panels, and tags: it resolves a window's properties, makes its panel, and holds the tags the properties name. Rule sources apply in ascending precedence: configured rules at `PRECEDENCE.rules` (100), the saved arrangement at `PRECEDENCE.persisted` (200), and the native pose property at `PRECEDENCE.native` (300). Saved state supplies pose, size, and tags; the native source supplies a hand-placed pose. The rule list and the saved arrangement must be registered before adoption resolves the first window, so a rules source a configuration inserts goes `before = 'desktop/adoption'`. Tags are held, so whichever entry names a workspace tag first makes it, and the entries need no other order.

Drops reach pose memory, persistence, and arrangement through `lunette/drops`, which the interaction provider emits to when a grab ends. None of them requires interaction.

A placement request can supply resolved properties directly. Otherwise the provider calls `rules:resolve(window)`. Request defaults fill only properties that remain unset; resolved properties take precedence. The provider freezes the merged properties and returns them with the panel. The `panelOptions` callback receives those properties, the window, and the base mapping. The base maps `pose`, `width`, `height`, `title`, `priority`, `chrome`, and `curve` to panel options. Other resolved properties remain available to consumers and are not passed to panel creation by the base mapping.

A pose may be a `Mat4` or the encoded string held in the `lunette.pose` property. The provider decodes strings. An invalid pose string is reported and ignored. Properties named by `tags` cause the provider to hold and join each tag. A missing tag is created and reported at info level. Placement owns the panel, tag holds, memberships, and hidden override through effects. A panel removal ends the placement.

The schema in [config.luau](../config.luau) is the source of truth for the `panelOptions` callback and its default. The contracts are the source of truth for service types.

## Decisions

Placement is several entries, following the integration component of section 6.5 of the Cordis paper. One policy entry was rejected because replacing the layout, the rules, or persistence would mean copying all of it. Pose memory is one consumer that both writes the pose on a drop and registers the rule source that reads it, because either half without the other loses hand-placed poses across reloads. A provider method for the reading half was rejected because a substitute adoption provider would carry half a feature. It is a child of `desktop/adoption`, enabled before the start, so its source is registered before the first window resolves. `desktop/arrange` learns of placements from the placement contract, which carries the resolved properties; `panels:onAdded` reaches every panel without them.

Placement is the integration component of section 6.5 of the Cordis paper. Mapping properties to panel options inside rules was rejected because rules would then require panels and tags. Placement announces every placement, so a plugin that places windows itself is arranged like an adopted one.

The default `panelOptions` hook is where a resolved property reaches a panel. A configuration can replace the mapping without replacing the placement provider.

## Known gaps

Placement inspection does not retain resolved-property provenance. The provider's inspection snapshot reports that limitation. Shared contract and callback guarantees remain in [the Lua API](../../../../docs/dev/lua-api.md#contracts).
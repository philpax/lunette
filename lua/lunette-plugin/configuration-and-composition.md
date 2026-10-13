# Configuration and composition

## Provider definitions and schemas

Configured providers and consumers expose `definition` and `define`. `definition` uses default settings; `define(options)` binds defaults and an optional name, validating the bound values before returning a definition. Each activation resolves its configuration afresh. A provider replacement implements the existing contract.

One schema descriptor supplies input and resolved settings types, runtime validation, and editor metadata. Schema defaults are validated when the descriptor is built; the facade parses the descriptor's defaults when creating the configured module. Without a schema, the configured module accepts an empty object and no options. Runtime parsing is necessary because the Luau checker does not reject every invalid table shape. A definition's `resolve` validates configuration without running its initializer.

Objects merge recursively by declared fields; arrays, maps, unions, and atomic values replace as a whole, including when empty. Numbers and vectors require finite components. Runtime callback validation checks only that a value is a function; callback signatures are checked statically. The [configuration schema guide](../../docs/guide/configuration-schema.md) owns constructor details and validation errors.

Hooks provide variation that an external wrapper cannot reach. They receive the usual arguments followed by `base`; calling it keeps the default behavior, omitting it replaces that behavior. Hooks run synchronously on the caller's stack. Provider references describe their specific hooks: [keyboard](../lunette-plugins/keyboard/README.md), [interaction](../lunette-plugins/interaction/README.md), and [laser](../lunette-plugins/laser/README.md).

## Compose entries and patches

A composition is an ordered list of `{ id, definition, config }` entries. A definition may be a factory; composition calls it to read its schema, and session start calls it again. Factories must be side-effect-free; resource acquisition belongs in activation. `plugin.compose(entries, patches)` returns a validated, frozen copy and starts no runtime.

Patches disable, replace, or configure an entry by id, or insert an entry at the end or before or after another entry. `plugin.configure(id, target)(config)` creates a typed configuration patch without calling a target factory. Composition verifies that the entry has the target definition. It rejects duplicate ids or patches, missing targets, malformed or unknown fields, and patches that do nothing or both disable and change an entry. Under a schema, object fields merge recursively and other values replace; without schema metadata, patched configuration replaces the original.

Composition does not make activation transactional. Entry order is part of the composition; dependency matching, reservations, retry, and lifecycle planning belong to [Plugin runtime](../../docs/dev/architecture.md#plugin-runtime). Desktop-specific settings and patches are described in [Desktop configuration](../../docs/guide/desktop-configuration.md).

## Start and manage a session

`@lunette-plugin/management.start` is the single session start path. It resolves every entry's configuration before creating the runtime, so a preflight error prevents any entry from activating. Initializer failures after start remain local to their instances. The id `composition` is reserved.

The returned service manages entries and their current and last-good configurations. Invalid configuration is rejected before disturbing a live activation. Recovery retries the last configuration observed active; restoration reinstalls a removed entry from its retained definition and configuration as a new instance. Management protects itself, explicitly protected entries, their providers, and parent owners. Changing the raw runtime bypasses that policy. Replacement is not transactional: cleanup failure quarantines the entry and retains its reservation until session restart. [`@lunette-contracts/composition`](../lunette-contracts/composition.luau) defines the service API.

Runtime snapshots are detached and do not invoke callbacks or drain pending work. Broker inspection returns registration metadata without invoking plugin callbacks.

## Decisions

A shared descriptor avoids separate static, runtime, and editor schemas drifting. Inferring configuration types from defaults was rejected because optional values, unions, and empty collections do not reveal their intended types. Preflight cannot predict initializer or native acquisition failures; those remain activation-time errors.

Composition and runtime start are separate so configurations can compose entries without the shipped desktop. Management owns the one start path; a second path that validated only during activation would disagree about when configuration errors appear.

Typed patches carry their target definition because the pinned checker widens some inferred literals, and checking options against the wrong definition would be unsound. A patch type discriminated by id was rejected because inserted entries would require a catch-all that could accept mistyped settings for shipped entries.

Hooks are definition options rather than wrapper plugins: providers may call internal closures or perform bulk work that an outside wrapper cannot intercept.

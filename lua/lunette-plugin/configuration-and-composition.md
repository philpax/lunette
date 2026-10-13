# Configuration and composition

Plugin authors compose definitions into entries without depending on the shipped desktop. The [facade declarations](init.luau) own entry and patch types; [writing plugins](../../docs/guide/writing-plugins.md) links checked compositions.

## Provider definitions and schemas

Configured modules expose `definition` with default settings and `define` for bound defaults or a name. Each activation resolves fresh settings. [Schemas](../../docs/guide/configuration-schema.md) define merging: objects inherit field by field; other values replace, including empty collections. Runtime parsing remains necessary because the checker does not reject every invalid table shape.

Hooks receive normal arguments followed by `base`. Calling it retains default behavior; omitting it replaces behavior. Hooks run synchronously. Each provider documents its constraints.

## Compose entries and patches

`plugin.compose` validates and freezes an ordered entry list without starting it. Definition factories can run during composition and again at startup; they must have no side effects. Acquire resources only during activation.

Patches target existing ids or insert before, after, or at the end. Composition rejects duplicate ids or patches, missing targets, and contradictory changes. Typed configuration patches verify the target definition, preventing configuration from being checked against a different schema. [Desktop configuration](../../docs/guide/desktop-configuration.md) describes desktop settings and patches.

## Start and manage a session

`management.start` resolves every entry's configuration before creating a runtime. Invalid settings prevent all activation; initializer or native acquisition failures remain activation-time errors. The id `composition` is reserved. The returned [composition service](../lunette-contracts/composition.luau) manages that entry list.

Invalid replacement settings leave a live activation undisturbed. Valid replacement ends it before starting the new one; replacement is not transactional. Recovery retries the last configuration observed active. Restoring a removed entry creates a new instance from its retained definition and configuration. Cleanup failure quarantines the entry and retains its reservation until session restart.

Protection includes designated entries, their bound providers, and parent owners. Direct runtime mutations bypass this policy. Snapshots and broker inspection are detached observations that invoke no callbacks and drain no pending work. Native lifecycle planning belongs to the [runtime specification](../../docs/dev/architecture.md#plugin-runtime).

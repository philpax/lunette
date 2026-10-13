# Configuration schemas

A plugin's schema supplies runtime validation, runtime-manager editor metadata, and Luau configuration types. The [schema constructors](../../lua/lunette-plugin/schema/init.luau) own the API; [`examples/first-plugin/uptime.luau`](../../examples/first-plugin/uptime.luau) shows a complete configured consumer.

## Declaring a shape

Build one descriptor, derive `Config` with `schema.Input` and `Settings` with `schema.Output`, and pass it to the provider or consumer definition. `Config` permits caller overrides; resolved `Settings` requires defaulted fields and makes containers read-only. An omittable root object needs a default. A configured module without a schema accepts no options.

`default(child)(value)` validates the default during construction. Use explicit singleton type arguments for literals and unions of values for enums, as the [constructor declarations](../../lua/lunette-plugin/schema/init.luau) show; the pinned checker otherwise widens literal types. Native vectors represent three-dimensional positions, directions, and offsets and require finite components.

## Merging and validation

Objects merge by declared field. Arrays, maps, union values, and atomic values replace as a whole, including when empty. An empty object preserves inherited fields; an empty array clears the array. `resolve` applies overrides over an existing output before descriptor defaults. [Composition](../../lua/lunette-plugin/configuration-and-composition.md) uses this rule for definition defaults and entry settings.

Runtime validation remains required: the checker does not reject every unknown field or wrong dictionary value. Parsing rejects unknown fields, metatables, recursive tables, and excessive nesting. Callback signatures are checked only statically.

## Code-backed fields

A refinement checks parsed output after defaults and nested validation, so it can enforce relationships between fields. A custom validator must return its input unchanged; validation can run repeatedly. Custom values and callbacks retain identity and are not copied, traversed, or frozen. Their editor fields are read-only.

## Inspection and errors

`inspect` returns immutable metadata derived from the same descriptor used to parse. `describe` attaches editor text rather than a separate editor schema. Parse errors identify the option path; [error declarations](../../lua/lunette-plugin/schema/runtime.luau) define the structured error fields and codes. Rejected runtime-manager drafts remain editable without replacing the live configuration.

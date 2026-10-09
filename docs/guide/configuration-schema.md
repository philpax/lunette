# Configuration schemas

`@lunette-plugin/schema` builds immutable configuration descriptors. One descriptor supplies runtime parsing, the metadata the [runtime manager](runtime-manager.md) edits, and the Luau input and output types. `lua/lunette-plugin/schema/init.luau` is the constructor API, and `runtime.luau` holds the parser.

## Declaring a shape

```luau
local schema = require '@lunette-plugin/schema'

local descriptor = schema.object {
  count = schema.default(schema.number { minimum = 1, integer = true })(3),
  title = schema.string(),
  note = schema.optional(schema.string()),
  style = schema.default(schema.object {
    width = schema.default(schema.number())(2),
  }) { width = 2 },
  position = schema.default(schema.vector())(vector.pack(0, 1, 0)),
  modes = schema.default(schema.array(schema.string())) {},
  mode = schema.default(schema.union(
    schema.literal<<'quiet'>>('quiet'),
    schema.literal<<'active'>>('active')
  ))('quiet'),
}

type Config = schema.Input<typeof(descriptor)>
type Settings = schema.Output<typeof(descriptor)>

local config: Config = { title = 'Sample', style = {} }
local settings: Settings = descriptor.parse(config, 'sample')
```

`Config` makes defaulted fields optional and keeps containers writable. `Settings` requires every defaulted value and makes object fields and collections read-only. Optional fields are optional in both. A function that only reads a resolved collection takes `{ read [number]: T }` or `{ read [string]: T }`.

`default(child)(value)` is curried. It validates the value when the descriptor is built. A literal takes an explicit singleton type argument, as in `schema.literal<<'quiet'>>('quiet')`.

`parse(value, name?)` validates an unknown value and returns the output, or raises. A name prefixes errors with `plugin <name>`. A required root object rejects nil; a root that may be omitted needs a `default`.

`resolve(value, base, name?)` applies `value` over an existing output `base`. Object fields inherit from the base before the descriptor's defaults, and arrays and maps replace. The plugin facade uses it to apply an entry's configuration over a definition's defaults.

## Constructors

| Constructor | Accepts |
|---|---|
| `number(options?)` | A finite number, with optional `minimum`, `maximum`, `integer`, and `positive`, which excludes zero. |
| `string(options?)` | A string, with optional `minLength`, `maxLength`, and a Lua `pattern`. Lengths count bytes. |
| `boolean()` | A boolean. |
| `vector()` | A native vector with finite components. |
| `literal<T>(value)` | Exactly that string or boolean. |
| `union(first, second)` | A value either child accepts. More alternatives nest. |
| `object(shape)` | A plain table with only the declared string fields. |
| `array(child, options?)` | A dense, one-based list of child values, with optional `minLength` and `maxLength`. |
| `map(child, options?)` | A table of string keys to child values, with optional `minLength` and `maxLength`. |
| `optional(child)` | Nil or a child value. |
| `default(child)(value)` | A child value, or `value` when absent. A nil default is rejected. |
| `refine(child)(validate, description?)` | A child value that `validate` accepts; `validate` raises to reject. |
| `callback(witness)` | A function. The witness gives its static type; the runtime checks only that it is a function. |
| `custom<T> { runtimeType, validate }` | A value whose `typeof` is `runtimeType` and that `validate` accepts. |
| `describe(child) { label?, description? }` | A child value, with text for an editor. |

Objects merge field by field, and an empty object keeps every default. Arrays, maps, and union values replace entirely, even when empty. Constructors reject unknown options and tables with metatables.

## Code-backed fields

```luau
local transform = function(value: number): string
  return tostring(value)
end
local callback = schema.default(schema.callback(transform))(transform)
local interval = schema.refine(schema.object {
  lower = schema.number(),
  upper = schema.number(),
})(function(value)
  assert(value.lower < value.upper, 'lower must precede upper')
end, 'An ordered interval.')
```

A refinement receives the parsed output, after defaults and nested validation, and expresses a constraint across fields.

A custom validator checks a value and returns it unchanged. The parser raises if the validator returns a different value, compared with `rawequal`. The parser does not copy, traverse, or freeze a custom value, and callbacks and vectors also keep their identity.

## Inspection and errors

`inspect()` returns the descriptor's immutable metadata tree. Each node has a `kind`, and, where they apply, `fields`, `child`, `alternatives`, constraints, defaults, labels, and descriptions. `merge` is `object` or `replace`. Callback and custom nodes have `readOnly = true`, so a generic editor leaves them alone.

A parse failure raises an immutable error with `name`, `path`, `code`, and `message`, and `tostring(error)` renders the name and option path. A union failure includes each alternative's error. Recursive tables raise an error, and parsing stops below 64 nested descriptor levels with a `depth` error.

## Decisions

The runtime tree is the source of editor metadata, because a separately declared editor schema could disagree with validation. Type functions derive the Luau types from the same constructors.

Custom schemas validate rather than transform. Defaults and bases are validated more than once, so a transforming validator would apply its transformation repeatedly; the parser rejects a changed value instead.

`default` is curried because the pinned Luau checker widens nested read-only properties through a two-argument generic. Literals take explicit singleton type arguments because a generic call widens strings and booleans; `schema.literal('quiet' :: 'quiet')` also works.

## Known gaps

The pinned Luau checker accepts some wrong dictionary values in function arguments and optional dictionary assignments, and it does not reject every unknown object field. Runtime parsing rejects both. Callback signatures are checked only statically. The runtime cannot prove that a custom validator's `T` is correct or that the validator leaves its input unchanged.

A definition made with `plugin.define` has no descriptor, and the runtime manager offers no configuration controls for it. A configured provider or consumer without a `schema` has an empty object descriptor and takes no options.

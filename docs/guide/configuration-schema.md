# Configuration schemas

`@lunette-plugin/schema` provides immutable configuration descriptors. A descriptor supplies runtime parsing, editor metadata, and the Luau input and output types. `lua/lunette-plugin/schema/init.luau` is the constructor API, and `runtime.luau` owns the parser tree. Inspection returns that same tree rather than a separately maintained description.

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

`Config` accepts omitted defaulted fields and keeps its object fields, arrays, and maps writable. `Settings` requires their resolved values and makes schema-declared object fields and collection indexers read-only. Optional fields remain optional in both types. The shape is declared once; neither type repeats its fields. `Schema<I, O>` describes a descriptor with input type `I` and output type `O`. A method that only reads resolved collections accepts `{ read [number]: T }` or `{ read [string]: T }`; a method that edits a collection needs a separate mutable copy.

`default(child)(value)` is curried. Its value has the child's output type. The constructor validates the value immediately and snapshots declared containers. Separate calls prevent generic inference from widening nested fields while checking a default.

`parse(value, name?)` accepts an unknown runtime value and returns the output type. It raises for invalid input. Passing a name gives diagnostics the prefix `plugin <name>`. A required root object does not accept nil; an omitted root needs an explicit `default` wrapper.

## Constructors

| Constructor | Runtime rule |
|---|---|
| `number(options?)` | A finite number, with optional `minimum`, `maximum`, and `integer` constraints. |
| `string(options?)` | A string, with optional `minLength`, `maxLength`, and Lua `pattern` constraints. Length counts bytes. |
| `boolean()` | A boolean. |
| `vector()` | A native vector with finite x, y, and z components. |
| `literal<T>(value)` | The exact string or boolean value. An explicit singleton argument preserves the closed static type. |
| `union(first, second)` | A value accepted by either child. More alternatives use nested unions. |
| `object(shape)` | A plain table containing only declared string fields. Each field is parsed even when absent. |
| `array(child, options?)` | A dense, one-based plain table of child values. |
| `map(child, options?)` | A plain table of string keys and child values. |
| `optional(child)` | Nil or a child value. |
| `default(child)(value)` | The declared value for absent input, otherwise a child value. Nil defaults are rejected. |
| `refine(child)(validate, description?)` | A child value followed by a typed validator that raises on failure. |
| `callback(witness)` | A function with the witness's static signature. Runtime validation checks only the function kind. |
| `custom<T> { runtimeType, validate }` | An atomic code-backed value. `runtimeType` names its `typeof`, and `validate(unknown)` returns the original value typed as `T` or raises. |
| `describe(child) { label?, description? }` | A descriptor carrying optional editor text. |

Arrays and maps accept `minLength` and `maxLength`. Bounds must be finite and ordered. Length bounds must be nonnegative integers. Constructor options and object shapes reject metatables and unknown options. Array outputs cannot contain nil. Custom validators cannot replace an entry with nil or any other value.

Objects merge declared fields recursively. A supplied empty object retains sibling defaults. Arrays and maps replace completely, including when the supplied collection is empty. Supplied union values also replace completely. An alternative uses its own declared defaults rather than inheriting fields from the previous union value, even when both values match the same alternative. Omission retains and validates the base value. Metadata records object merging separately from replacement. A map is not inferred from a default table's keys.

`resolve(value, base, name?)` validates an existing output value and applies input over it. Object fields inherit the base before descriptor defaults. Arrays and maps still replace. This permits a definition to retain its resolved settings as the base for later configuration. Invalid bases and overrides raise; false and other invalid values never become an empty configuration.

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

Refinements receive the parsed output after defaults and nested validation. They support constraints across fields without a second shape declaration. A plugin may retain an additional validator at its integration boundary.

Custom validators validate their value contract, including metatables and cycles. The parser does not traverse, copy, or freeze custom values. Validation must return the input value without transforming or mutating it. The runtime enforces return identity with `rawequal`; a fresh table or changed scalar raises a structured `custom` error stating that the validator must return the original value. `__eq` does not satisfy this contract. A validator narrows the original `unknown` value to `T` after checking it. Construction validates defaults, and parsing and resolution validate defaults and bases again. Repeated validation therefore preserves the original reference rather than applying a transformation repeatedly. Callback references and native vectors also retain their identity or value. Descriptor and metadata immutability does not make an externally owned custom reference immutable.

## Inspection and diagnostics

`inspect()` returns immutable `Metadata`. Its `kind` distinguishes object, array, map, scalar, wrapper, and code-backed nodes. The tree includes `fields`, `child`, `alternatives`, constraints, defaults, labels, and descriptions where applicable. Both the metadata properties and the indexers in `fields` and `alternatives` are read-only. `merge` is `object` or `replace`. Callback and custom nodes have `readOnly = true` for a generic editor. Wrappers preserve that flag. Their code and value references remain available to code-aware tools; inspection does not serialize them.

A parser failure raises an immutable `Error` table with `name`, `path`, `code`, and `message`. The path has a read-only indexer and contains string fields and numeric array indices. `tostring(error)` renders the name prefix and option path. Nested failures retain their full path. Union failures include the alternative diagnostics. String matching runs under a protected call at the current field path because some malformed patterns raise only for particular inputs. Wrong numeric types are described with `typeof` without invoking an input's `__tostring`. A container rejects its metatable before field access or iteration. Cycles reached through declared containers raise rather than recurse indefinitely. Traversal permits at most 64 descriptor child steps from the root, including wrappers and union alternatives. A deeper traversal raises a structured `depth` error at the current path before exhausting the parser stack. Custom values are atomic and do not undergo this traversal. Shared noncyclic tables are copied independently.

## Decisions

The runtime tree is the source of editor metadata because a separately declared editor schema can diverge from runtime validation. Type witnesses project the same constructor composition into Luau types. Witness functions are not validators.

Custom schemas validate rather than normalize. Identity-preserving validation keeps callbacks, metatable-backed objects, and other code-backed customization intact when defaults and bases are validated repeatedly. Returning a transformed value would apply that transformation at construction and again during parsing or resolution. The runtime rejects that return instead of silently replacing the value.

Defaults use a curried API because the pinned Luau checker widens nested read properties with a two-argument generic default constructor. Singleton literals use explicit singleton type arguments because standalone generic calls widen strings and booleans in the pinned checker. A singleton expression annotation also works: `schema.literal('quiet' :: 'quiet')`.

## Known gaps

The pinned Luau checker accepts some wrong dictionary values in function arguments and in optional dictionary assignments, including equivalent dictionary types without descriptors. Required map input and output assignments retain their value types and have negative checker fixtures. Runtime map validation rejects wrong values in every case.

The checker does not statically reject every unknown object field; runtime objects are closed. Callback signatures are static only. Runtime reflection cannot validate their parameter and return types. The runtime checks a custom value's `typeof` and return identity, but cannot prove the validator's claimed `T` or prevent the validator from mutating its input. Correct narrowing and side-effect-free validation remain the author's responsibility.

Configured providers and consumers expose a descriptor only when their authoring spec supplies `schema`. Every configurable built-in, development plugin, and example supplies one. Legacy external modules may still use default-table validation, and raw definitions remain valid without descriptors. The schema API declares no persistence format.

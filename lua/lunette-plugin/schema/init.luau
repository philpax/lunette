-- Configuration descriptors derive input types, resolved types, validation, and metadata together.

local runtime = require '@lunette-plugin/schema/runtime'
local schema = {}

export type Schema<I, O> = {
  read input: (I) -> I,
  read output: (O) -> O,
  read parse: (unknown, string?) -> O,
  read resolve: (unknown, O, string?) -> O,
  read inspect: () -> Metadata,
}
export type Metadata = runtime.Node
export type Path = runtime.Path
export type Error = runtime.Error
export type ErrorCode = runtime.ErrorCode
export type Annotation = runtime.Annotation
export type NumberOptions = {
  read minimum: number?,
  read maximum: number?,
  read integer: boolean?,
  read positive: boolean?,
}
export type LengthOptions = { read minLength: number?, read maxLength: number? }
export type StringOptions = LengthOptions & { read pattern: string? }
export type Custom<T> = { read runtimeType: string, read validate: (unknown) -> T }

export type function Input(descriptor: type): type
  for name, field in descriptor:properties() do
    if name:value() == 'input' then
      local witness = field.read
      assert(witness, 'schema input witness is not readable')
      local parameters = witness:parameters().head
      assert(parameters and parameters[1], 'schema input witness has no parameter')
      return parameters[1]
    end
  end
  error 'not a schema descriptor'
end

export type function Output(descriptor: type): type
  for name, field in descriptor:properties() do
    if name:value() == 'output' then
      local witness = field.read
      assert(witness, 'schema output witness is not readable')
      local parameters = witness:parameters().head
      assert(parameters and parameters[1], 'schema output witness has no parameter')
      return parameters[1]
    end
  end
  error 'not a schema descriptor'
end

export type function ObjectInput(shape: type): type
  local result = types.newtable()
  for key, property in shape:properties() do
    local child = property.read
    assert(child, 'schema object field is not readable')
    local found = false
    for name, field in child:properties() do
      if name:value() == 'input' then
        local witness = field.read
        assert(witness, 'schema input witness is not readable')
        local parameters = witness:parameters().head
        assert(parameters and parameters[1], 'schema input witness has no parameter')
        result:setproperty(key, parameters[1])
        found = true
      end
    end
    assert(found, 'schema object field is not a descriptor')
  end
  return result
end

export type function ObjectOutput(shape: type): type
  local result = types.newtable()
  for key, property in shape:properties() do
    local child = property.read
    assert(child, 'schema object field is not readable')
    local found = false
    for name, field in child:properties() do
      if name:value() == 'output' then
        local witness = field.read
        assert(witness, 'schema output witness is not readable')
        local parameters = witness:parameters().head
        assert(parameters and parameters[1], 'schema output witness has no parameter')
        result:setreadproperty(key, parameters[1])
        found = true
      end
    end
    assert(found, 'schema object field is not a descriptor')
  end
  return result
end

-- Reads each listed descriptor's witness in `direction`, so a union's types are the union of its alternatives' types.
type function Alternatives(list: type, direction: type): type
  local indexer = list:indexer()
  assert(indexer, 'schema union alternatives are not a list')
  local element = indexer.readresult
  local members = if element:is 'union' then element:components() else { element }
  local results: { type } = {}
  for _, member in members do
    local found = false
    for name, field in member:properties() do
      if name:value() == direction:value() then
        local witness = field.read
        assert(witness, 'schema witness is not readable')
        local parameters = witness:parameters().head
        assert(parameters and parameters[1], 'schema witness has no parameter')
        table.insert(results, parameters[1])
        found = true
      end
    end
    assert(found, 'schema union alternative is not a descriptor')
  end
  if #results == 1 then
    return results[1]
  end
  return types.unionof(table.unpack(results))
end

type UnionInput<L> = Alternatives<L, 'input'>
type UnionOutput<L> = Alternatives<L, 'output'>

-- Makes every property optional, keeping read-only properties read-only.
export type function Partial(shape: type): type
  local result = types.newtable()
  for key, property in shape:properties() do
    local value = property.read
    assert(value, 'schema object field is not readable')
    if property.write then
      result:setproperty(key, types.optional(value))
    else
      result:setreadproperty(key, types.optional(value))
    end
  end
  return result
end

function schema.number(options: NumberOptions?): Schema<number, number>
  local properties = runtime.options(options, { minimum = true, maximum = true, integer = true, positive = true })
  runtime.bounds(properties, 'minimum', 'maximum', false)
  for _, flag in { 'integer', 'positive' } do
    if properties[flag] ~= nil and type(properties[flag]) ~= 'boolean' then
      runtime.fail('schema', { flag }, 'descriptor', 'must be a boolean')
    end
  end
  return runtime.wrap<<number, number>>(runtime.node('number', properties))
end

function schema.string(options: StringOptions?): Schema<string, string>
  local properties = runtime.options(options, { minLength = true, maxLength = true, pattern = true })
  runtime.bounds(properties, 'minLength', 'maxLength', true)
  if properties.pattern ~= nil then
    if type(properties.pattern) ~= 'string' then
      runtime.fail('schema', { 'pattern' }, 'descriptor', 'must be a string')
    end
    local ok, problem = pcall(string.match, '', properties.pattern :: string, 1)
    if not ok then
      runtime.fail('schema', { 'pattern' }, 'descriptor', 'is invalid: ' .. tostring(problem))
    end
  end
  return runtime.wrap<<string, string>>(runtime.node('string', properties))
end

function schema.boolean(): Schema<boolean, boolean>
  return runtime.wrap<<boolean, boolean>>(runtime.node 'boolean')
end

function schema.vector(): Schema<vector, vector>
  return runtime.wrap<<vector, vector>>(runtime.node 'vector')
end

function schema.literal<T>(value: T): Schema<T, T>
  if type(value) ~= 'string' and type(value) ~= 'boolean' then
    runtime.fail('schema', {}, 'descriptor', 'literal must be a string or boolean singleton')
  end
  return runtime.wrap<<T, T>>(runtime.node('literal', { value = value }))
end

function schema.enum<T>(values: { T }): Schema<T, T>
  local raw = runtime.plain(values, 'schema enum', {})
  local count = rawlen(raw :: any)
  if count == 0 then
    runtime.fail('schema enum', {}, 'descriptor', 'must list at least one value')
  end
  local seen: { [string]: boolean } = {}
  for key, value in raw do
    if type(key) ~= 'number' or key < 1 or key > count or key % 1 ~= 0 then
      runtime.fail('schema enum', {}, 'descriptor', 'must be a dense list of values')
    end
    if type(value) ~= 'string' then
      runtime.fail('schema enum', { key :: number }, 'descriptor', 'must be a string')
    end
    if seen[value :: string] then
      runtime.fail('schema enum', { key :: number }, 'descriptor', 'repeats ' .. (value :: string))
    end
    seen[value :: string] = true
  end
  return runtime.wrap<<T, T>>(runtime.node('enum', { values = table.freeze(table.clone(raw)) }))
end

-- `union { first, second, ... }` accepts a value that any alternative accepts, trying them in order.
function schema.union<L>(alternatives: L): Schema<UnionInput<L>, UnionOutput<L>>
  local raw = runtime.plain(alternatives, 'schema union', {})
  local count = rawlen(raw :: any)
  if count < 2 then
    runtime.fail('schema union', {}, 'descriptor', 'must list at least two alternatives')
  end
  local nodes: { Metadata } = {}
  local readOnly = false
  for key, child in raw do
    if type(key) ~= 'number' or key < 1 or key > count or key % 1 ~= 0 then
      runtime.fail('schema union', {}, 'descriptor', 'must be a dense list of alternatives')
    end
    local node = runtime.unwrap(child)
    nodes[key :: number] = node
    readOnly = readOnly or node.readOnly
  end
  return runtime.wrap<<UnionInput<L>, UnionOutput<L>>>(
    runtime.node('union', { alternatives = table.freeze(nodes), readOnly = readOnly })
  )
end

function schema.object<S>(shape: S): Schema<ObjectInput<S>, ObjectOutput<S>>
  local raw = runtime.plain(shape, 'schema object', {})
  local fields: { [string]: Metadata } = {}
  for key, child in raw do
    if type(key) ~= 'string' then
      runtime.fail('schema object', {}, 'descriptor', 'field names must be strings')
    end
    fields[key :: string] = runtime.unwrap(child)
  end
  return runtime.wrap<<ObjectInput<S>, ObjectOutput<S>>>(runtime.node('object', { fields = table.freeze(fields) }))
end

function schema.array<D>(child: D, options: LengthOptions?): Schema<{ Input<D> }, { read [number]: Output<D> }>
  local properties = runtime.options(options, { minLength = true, maxLength = true })
  runtime.bounds(properties, 'minLength', 'maxLength', true)
  properties.child = runtime.unwrap(child)
  return runtime.wrap<<{ Input<D> }, { read [number]: Output<D> }>>(runtime.node('array', properties))
end

function schema.map<D>(child: D, options: LengthOptions?): Schema<{ [string]: Input<D> }, { read [string]: Output<D> }>
  local properties = runtime.options(options, { minLength = true, maxLength = true })
  runtime.bounds(properties, 'minLength', 'maxLength', true)
  properties.child = runtime.unwrap(child)
  return runtime.wrap<<{ [string]: Input<D> }, { read [string]: Output<D> }>>(runtime.node('map', properties))
end

function schema.optional<D>(child: D): Schema<Input<D>?, Output<D>?>
  local node = runtime.unwrap(child)
  return runtime.wrap<<Input<D>?, Output<D>?>>(
    runtime.node('optional', { child = node, readOnly = node.readOnly, merge = node.merge })
  )
end

function schema.default<D>(child: D): (Output<D>) -> Schema<Input<D>?, Output<D>>
  local node = runtime.unwrap(child)
  return function(value: Output<D>): Schema<Input<D>?, Output<D>>
    local validated = runtime.defaultValue(node, value)
    return runtime.wrap<<Input<D>?, Output<D>>>(
      runtime.node('default', { child = node, value = validated, readOnly = node.readOnly, merge = node.merge })
    )
  end
end

-- Derives the descriptor of sparse overrides from an object: each field becomes optional and loses its default.
function schema.partial<D>(object: D): Schema<Partial<Input<D>>, Partial<Output<D>>>
  local node = runtime.unwrap(object)
  if node.kind ~= 'object' then
    runtime.fail('schema partial', {}, 'descriptor', 'takes an object descriptor, not a ' .. node.kind)
  end
  local fields: { [string]: Metadata } = {}
  for key, field in node.fields :: { read [string]: Metadata } do
    local child = if field.kind == 'default' or field.kind == 'optional' then field.child :: Metadata else field
    fields[key] = runtime.node('optional', {
      child = child,
      readOnly = child.readOnly,
      merge = child.merge,
      label = field.label,
      description = field.description,
    })
  end
  return runtime.wrap<<Partial<Input<D>>, Partial<Output<D>>>>(
    runtime.node('object', { fields = table.freeze(fields) })
  )
end

function schema.refine<D>(child: D): ((Output<D>) -> ()) -> Schema<Input<D>, Output<D>>
  local node = runtime.unwrap(child)
  return function(validate: (Output<D>) -> ()): Schema<Input<D>, Output<D>>
    if type(validate) ~= 'function' then
      runtime.fail('schema refine', {}, 'descriptor', 'validator must be a function')
    end
    -- The child validates and reconstructs Output<D> before the typed refinement receives it.
    local erased = function(value: unknown): unknown
      validate((value :: unknown) :: Output<D>)
      return value
    end
    return runtime.wrap<<Input<D>, Output<D>>>(
      runtime.node('refine', { child = node, validate = erased, readOnly = node.readOnly, merge = node.merge })
    )
  end
end

function schema.callback<F>(witness: F): Schema<F, F>
  if type(witness) ~= 'function' then
    runtime.fail('schema callback', {}, 'descriptor', 'witness must be a function')
  end
  return runtime.wrap<<F, F>>(runtime.node('callback', { value = witness, runtimeType = 'function', readOnly = true }))
end

function schema.custom<T>(spec: Custom<T>): Schema<T, T>
  local properties = runtime.options(spec, { runtimeType = true, validate = true })
  if type(properties.runtimeType) ~= 'string' or properties.runtimeType == '' then
    runtime.fail('schema custom', { 'runtimeType' }, 'descriptor', 'must be a nonempty typeof name')
  end
  if type(properties.validate) ~= 'function' then
    runtime.fail('schema custom', { 'validate' }, 'descriptor', 'must be a function')
  end
  properties.readOnly = true
  return runtime.wrap<<T, T>>(runtime.node('custom', properties))
end

function schema.describe<D>(child: D): (Annotation) -> Schema<Input<D>, Output<D>>
  local node = runtime.unwrap(child)
  return function(annotation: Annotation): Schema<Input<D>, Output<D>>
    local properties = runtime.options(annotation, { label = true, description = true })
    for key, value in properties do
      if type(value) ~= 'string' then
        runtime.fail('schema describe', { key }, 'descriptor', 'must be a string')
      end
    end
    local result: { [string]: unknown } = {}
    for key, value in (node :: unknown) :: { [string]: unknown } do
      result[key] = value
    end
    for key, value in properties do
      result[key] = value
    end
    return runtime.wrap<<Input<D>, Output<D>>>(runtime.node(node.kind, result))
  end
end

return table.freeze(schema)

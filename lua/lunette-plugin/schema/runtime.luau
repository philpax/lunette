-- The immutable descriptor tree is shared by parsing and editor inspection.

local runtime = {}

export type Path = { read [number]: string | number }
type MutablePath = { string | number }
export type Error = {
  read name: string,
  read path: Path,
  read code: string,
  read message: string,
}
export type Annotation = { read label: string?, read description: string? }
export type Kind =
  'number'
  | 'string'
  | 'boolean'
  | 'vector'
  | 'literal'
  | 'union'
  | 'object'
  | 'array'
  | 'map'
  | 'optional'
  | 'default'
  | 'refine'
  | 'custom'
  | 'callback'
export type Merge = 'object' | 'replace'
export type Node = {
  read kind: Kind,
  read readOnly: boolean,
  read merge: 'object' | 'replace',
  read label: string?,
  read description: string?,
  read fields: { read [string]: Node }?,
  read child: Node?,
  read alternatives: { read [number]: Node }?,
  read value: unknown,
  read minimum: number?,
  read maximum: number?,
  read integer: boolean?,
  read positive: boolean?,
  read minLength: number?,
  read maxLength: number?,
  read pattern: string?,
  read runtimeType: string?,
  read validate: ((unknown) -> unknown)?,
}

type Raw = { [unknown]: unknown }

local function pathText(path: Path): string
  local text = ''
  for _, key in path do
    if type(key) == 'number' then
      text ..= '[' .. tostring(key) .. ']'
    elseif string.match(key, '^[%a_][%w_]*$') then
      text ..= (if text == '' then '' else '.') .. key
    else
      text ..= '[' .. string.format('%q', key) .. ']'
    end
  end
  return if text == '' then '<root>' else text
end

local errorMetatable = table.freeze {
  __tostring = function(problem: Error): string
    -- A whole-configuration refinement names its own option paths.
    if #problem.path == 0 and problem.code == 'refinement' then
      return problem.name .. ': ' .. problem.message
    end
    return problem.name .. ': option ' .. pathText(problem.path) .. ' ' .. problem.message
  end,
}

function runtime.fail(name: string, path: Path, code: string, message: string): never
  error(
    table.freeze(
      setmetatable(
        { name = name, path = table.freeze(table.clone(path)), code = code, message = message },
        errorMetatable
      )
    ),
    0
  )
end

function runtime.at(path: Path, key: string | number): Path
  local result: MutablePath = {}
  for _, segment in path do
    table.insert(result, segment)
  end
  table.insert(result, key)
  return result
end

function runtime.plain(value: unknown, name: string, path: Path): Raw
  if type(value) ~= 'table' then
    runtime.fail(name, path, 'type', 'is a table, not a ' .. typeof(value))
  end
  if getmetatable(value :: Raw) ~= nil then
    runtime.fail(name, path, 'metatable', 'has a metatable; a plain table is required')
  end
  return value :: Raw
end

function runtime.finite(value: unknown): boolean
  return type(value) == 'number' and value == value and math.abs(value) < math.huge
end

function runtime.node(kind: Kind, properties: { [string]: unknown }?): Node
  local draft: { [string]: unknown } =
    { kind = kind, readOnly = false, merge = if kind == 'object' then 'object' else 'replace' }
  if properties then
    for key, value in properties do
      draft[key] = value
    end
  end
  -- Constructors validate the closed metadata shape before its mutable builder is frozen.
  return (table.freeze(draft) :: unknown) :: Node
end

local token = table.freeze {}

function runtime.unwrap(value: unknown): Node
  local raw = runtime.plain(value, 'schema', {})
  if rawget(raw, '_token') ~= token then
    runtime.fail('schema', {}, 'descriptor', 'is not a schema descriptor')
  end
  return rawget(raw, '_node') :: Node
end

function runtime.wrap<I, O>(node: Node): {
  read input: (I) -> I,
  read output: (O) -> O,
  read parse: (unknown, string?) -> O,
  read resolve: (unknown, O, string?) -> O,
  read inspect: () -> Node,
}
  return table.freeze {
    _token = token,
    _node = node,
    input = function(value: I): I
      return value
    end,
    output = function(value: O): O
      return value
    end,
    parse = function(value: unknown, name: string?): O
      -- Each constructor connects the erased tree to its witness types; parse validates before this cast.
      return (runtime.parse(node, value, if name then 'plugin ' .. name else 'schema') :: unknown) :: O
    end,
    resolve = function(value: unknown, base: O, name: string?): O
      -- Resolution validates the bound output before applying schema-directed overrides.
      return (runtime.resolve(node, value, base, if name then 'plugin ' .. name else 'schema') :: unknown) :: O
    end,
    inspect = function(): Node
      return node
    end,
  }
end

type Active = { [Raw]: boolean }

local function enter(value: unknown, name: string, path: Path, active: Active): Raw
  local raw = runtime.plain(value, name, path)
  if active[raw] then
    runtime.fail(name, path, 'cycle', 'contains a recursive table')
  end
  active[raw] = true
  for key in raw do
    if type(key) ~= 'string' and type(key) ~= 'number' then
      runtime.fail(name, path, 'key', 'has a key that is not a string or number')
    end
    if type(key) == 'number' and not runtime.finite(key) then
      runtime.fail(name, path, 'key', 'has a nonfinite numeric key')
    end
  end
  return raw
end

local function length(node: Node, count: number, name: string, path: Path): ()
  if node.minLength and count < node.minLength then
    runtime.fail(name, path, 'constraint', 'has fewer than ' .. tostring(node.minLength) .. ' entries')
  end
  if node.maxLength and count > node.maxLength then
    runtime.fail(name, path, 'constraint', 'has more than ' .. tostring(node.maxLength) .. ' entries')
  end
end

local parseAt: (Node, unknown, string, Path, unknown, Active, number) -> unknown
local maxDepth = 64

local function object(
  node: Node,
  given: unknown,
  name: string,
  path: Path,
  base: unknown,
  active: Active,
  depth: number
): unknown
  local raw = enter(given, name, path, active)
  local fields = node.fields :: { read [string]: Node }
  for key in raw do
    if type(key) ~= 'string' or fields[key] == nil then
      runtime.fail(name, runtime.at(path, key :: string | number), 'unknown', 'is not a declared field')
    end
  end
  local defaults = if type(base) == 'table' then base :: Raw else {}
  local result: Raw = {}
  for key, child in fields do
    result[key] =
      parseAt(child, rawget(raw, key), name, runtime.at(path, key), rawget(defaults, key), active, depth + 1)
  end
  active[raw] = nil
  return table.freeze(result)
end

local function collection(node: Node, given: unknown, name: string, path: Path, active: Active, depth: number): unknown
  local raw = enter(given, name, path, active)
  local count = 0
  for key in raw do
    count += 1
    if node.kind == 'array' then
      if type(key) ~= 'number' or key < 1 or key % 1 ~= 0 then
        runtime.fail(name, runtime.at(path, key :: string | number), 'key', 'is not a positive integer array index')
      end
    elseif type(key) ~= 'string' then
      runtime.fail(name, runtime.at(path, key :: string | number), 'key', 'is not a string map key')
    end
  end
  if node.kind == 'array' then
    for index = 1, count do
      if rawget(raw, index) == nil then
        runtime.fail(name, runtime.at(path, index), 'sparse', 'is missing from a dense array')
      end
    end
  end
  length(node, count, name, path)
  local result: Raw = {}
  for key, value in raw do
    local parsed =
      parseAt(node.child :: Node, value, name, runtime.at(path, key :: string | number), nil, active, depth + 1)
    if parsed == nil then
      runtime.fail(name, runtime.at(path, key :: string | number), 'nil', 'cannot resolve to nil in a collection')
    end
    result[key] = parsed
  end
  active[raw] = nil
  return table.freeze(result)
end

parseAt = function(
  node: Node,
  given: unknown,
  name: string,
  path: Path,
  base: unknown,
  active: Active,
  depth: number
): unknown
  if depth > maxDepth then
    runtime.fail(name, path, 'depth', 'exceeds the maximum schema depth of ' .. tostring(maxDepth))
  end
  local kind = node.kind
  if kind == 'default' then
    return parseAt(node.child :: Node, given, name, path, if base == nil then node.value else base, active, depth + 1)
  elseif kind == 'optional' then
    if given == nil and base == nil then
      return nil
    end
    return parseAt(node.child :: Node, given, name, path, base, active, depth + 1)
  elseif kind == 'refine' then
    local value = parseAt(node.child :: Node, given, name, path, base, active, depth + 1)
    local ok, problem = pcall(node.validate :: (unknown) -> unknown, value)
    if not ok then
      runtime.fail(name, path, 'refinement', tostring(problem))
    end
    return value
  end
  if given == nil and base ~= nil then
    given = base
  end
  if kind == 'union' then
    local failures = {}
    for _, alternative in node.alternatives :: { read [number]: Node } do
      -- An explicit union value replaces its base, and an omitted value is validated as a complete base.
      local ok, result = pcall(parseAt, alternative, given, name, path, nil, table.clone(active), depth + 1)
      if ok then
        return result
      end
      table.insert(failures, tostring(result))
    end
    runtime.fail(name, path, 'union', 'matches no alternative: ' .. table.concat(failures, '; '))
  elseif kind == 'object' then
    return object(node, given, name, path, base, active, depth)
  elseif kind == 'array' or kind == 'map' then
    return collection(node, given, name, path, active, depth)
  elseif kind == 'literal' then
    if given ~= node.value then
      runtime.fail(name, path, 'literal', 'must equal ' .. tostring(node.value))
    end
  elseif kind == 'number' then
    if type(given) ~= 'number' then
      runtime.fail(name, path, 'type', 'is a finite number, not a ' .. typeof(given))
    elseif not runtime.finite(given) then
      runtime.fail(name, path, 'type', 'is not a finite number')
    end
    local value = given :: number
    if node.minimum and value < node.minimum then
      runtime.fail(name, path, 'constraint', 'is below ' .. tostring(node.minimum))
    end
    if node.maximum and value > node.maximum then
      runtime.fail(name, path, 'constraint', 'is above ' .. tostring(node.maximum))
    end
    if node.integer and value % 1 ~= 0 then
      runtime.fail(name, path, 'constraint', 'is not an integer')
    end
    if node.positive and value <= 0 then
      runtime.fail(name, path, 'constraint', 'is not positive')
    end
  elseif kind == 'string' then
    if type(given) ~= 'string' then
      runtime.fail(name, path, 'type', 'is a string, not a ' .. typeof(given))
    end
    local text = given :: string
    length(node, #text, name, path)
    if node.pattern then
      local ok, matched = pcall(string.match, text, node.pattern, 1)
      if not ok then
        runtime.fail(name, path, 'pattern', 'pattern is invalid: ' .. tostring(matched))
      end
      if not matched then
        runtime.fail(name, path, 'constraint', 'does not match ' .. node.pattern)
      end
    end
  elseif kind == 'vector' then
    if typeof(given) ~= 'vector' then
      runtime.fail(name, path, 'type', 'is a vector, not a ' .. typeof(given))
    end
    local value = given :: vector
    local components: { [string]: number } = { x = value.x, y = value.y, z = value.z }
    for axis, component in components do
      if not runtime.finite(component) then
        runtime.fail(name, runtime.at(path, axis), 'type', 'is not a finite number')
      end
    end
  elseif kind == 'boolean' then
    if type(given) ~= 'boolean' then
      runtime.fail(name, path, 'type', 'is a boolean, not a ' .. typeof(given))
    end
  elseif kind == 'callback' then
    if type(given) ~= 'function' then
      runtime.fail(name, path, 'type', 'is a function, not a ' .. typeof(given))
    end
  elseif kind == 'custom' then
    if typeof(given) ~= node.runtimeType then
      runtime.fail(name, path, 'type', 'is a ' .. (node.runtimeType :: string) .. ', not a ' .. typeof(given))
    end
    local ok, result = pcall(node.validate :: (unknown) -> unknown, given)
    if not ok then
      runtime.fail(name, path, 'custom', tostring(result))
    end
    if not rawequal(result, given) then
      runtime.fail(
        name,
        path,
        'custom',
        'custom validator must return the original value; transformations are not supported'
      )
    end
    return given
  end
  return given
end

function runtime.parse(node: Node, value: unknown, name: string): unknown
  return parseAt(node, value, name, {}, nil, {}, 0)
end

function runtime.resolve(node: Node, value: unknown, base: unknown, name: string): unknown
  local validated = runtime.parse(node, base, name)
  return parseAt(node, value, name, {}, validated, {}, 0)
end

function runtime.defaultValue(node: Node, value: unknown): unknown
  if value == nil then
    runtime.fail('schema default', {}, 'default', 'must not be nil; use optional instead')
  end
  return runtime.parse(node, value, 'schema default')
end

function runtime.options(value: unknown, allowed: { [string]: boolean }): { [string]: unknown }
  if value == nil then
    return {}
  end
  local raw = runtime.plain(value, 'schema', {})
  for key in raw do
    if type(key) ~= 'string' or not allowed[key] then
      runtime.fail('schema', {}, 'descriptor', 'has an unknown constructor option ' .. tostring(key))
    end
  end
  return table.clone(raw) :: { [string]: unknown }
end

function runtime.bounds(options: { [string]: unknown }, lower: string, upper: string, integral: boolean): ()
  for _, key in { lower, upper } do
    local value = options[key]
    if
      value ~= nil
      and (not runtime.finite(value) or (integral and ((value :: number) < 0 or (value :: number) % 1 ~= 0)))
    then
      runtime.fail(
        'schema',
        { key },
        'descriptor',
        'must be a ' .. (if integral then 'nonnegative integer' else 'finite number')
      )
    end
  end
  if options[lower] ~= nil and options[upper] ~= nil and (options[lower] :: number) > (options[upper] :: number) then
    runtime.fail('schema', {}, 'descriptor', lower .. ' must not exceed ' .. upper)
  end
end

return runtime

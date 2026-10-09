-- Pure configuration drafts; schema validation and applying a draft belong to the composition service.

local schema = require '@lunette-plugin/schema'
local editor = {}

export type Path = { read [number]: string | number }
type MutablePath = { string | number }
export type Control = 'group' | 'boolean' | 'number' | 'string' | 'choice' | 'optional' | 'array' | 'map' | 'readonly'
export type Code = 'path' | 'readonly' | 'input' | 'key'
export type Problem = { read path: Path, read code: Code, read message: string }
export type Model = {
  read metadata: schema.Metadata,
  read defaults: unknown,
  read value: unknown,
}
export type Row = {
  read path: Path,
  read label: string,
  read description: string?,
  read metadata: schema.Metadata,
  read control: Control,
  read value: unknown,
  read text: string,
  read escaped: boolean,
  read choices: { read [number]: unknown }?,
  read optional: boolean,
  read readOnly: boolean,
  read reason: string?,
  read canReset: boolean,
  read canAdd: boolean,
  read canRemove: boolean,
}
type Raw = { [unknown]: unknown }
local hydrate: (schema.Metadata, unknown, unknown, { [Raw]: boolean }) -> unknown
local flatten: (schema.Metadata, unknown, Path, { Row }, { [Raw]: boolean }, unknown, boolean) -> ()
local at: (unknown, Path) -> unknown
local replace: (unknown, Path, number, unknown) -> unknown
local seed: (schema.Metadata, unknown?) -> (unknown, string?)
local parse: (schema.Metadata, unknown) -> (unknown, string?)
local opaque: (schema.Metadata, unknown?, { [Raw]: boolean }?) -> boolean
local plain: (unknown) -> boolean
local unwrap: (schema.Metadata) -> (schema.Metadata, boolean)
local shape: (schema.Metadata, unknown) -> (MutablePath?, string?)
local stringText: (string) -> (string, boolean)
local decodeText: (string) -> (string?, string?)

function editor.new(metadata: schema.Metadata, config: unknown): Model
  local defaults = hydrate(metadata, nil, nil, {})
  local value = hydrate(metadata, config, defaults, {})
  return table.freeze { metadata = metadata, defaults = defaults, value = value }
end

function editor.draft(model: Model): unknown
  return model.value
end

function editor.rows(model: Model): { read [number]: Row }
  local rows: { Row } = {}
  flatten(model.metadata, model.value, {}, rows, {}, model.defaults, false)
  return table.freeze(rows)
end

local function problem(path: Path, code: Code, message: string): (Model?, Problem?)
  return nil, table.freeze { path = table.freeze(table.clone(path)), code = code, message = message }
end

local function find(model: Model, path: Path, action: 'edit' | 'reset' | 'collection' | 'remove'): (Row?, Problem?)
  for _, row in editor.rows(model) do
    local matches = #row.path == #path
    for index, key in path do
      matches = matches and row.path[index] == key
    end
    if matches then
      local permitted = if action == 'remove' then row.canRemove else not row.readOnly
      if not permitted or (action == 'reset' and not row.canReset) or (action == 'collection' and not row.canAdd) then
        local _, failure = problem(path, 'readonly', row.reason or 'this action cannot safely edit the option')
        return nil, failure
      end
      return row, nil
    end
  end
  local _, failure = problem(path, 'path', 'the option is not available')
  return nil, failure
end

local function finite(value: number): boolean
  return value == value and math.abs(value) < math.huge
end

local function pack(value: vector, key: string | number, component: number): vector
  return vector.pack(
    if key == 'x' then component else value.x,
    if key == 'y' then component else value.y,
    if key == 'z' then component else value.z
  )
end

local function commit(model: Model, path: Path, value: unknown): (Model?, Problem?)
  if #path > 0 then
    local parentPath = table.clone(path) :: MutablePath
    local key = table.remove(parentPath)
    if key == nil then
      return problem(path, 'path', 'the option is not available')
    end
    local parent = at(model.value, parentPath)
    if typeof(parent) == 'vector' then
      if type(value) ~= 'number' then
        return problem(path, 'input', 'a vector component needs a finite number')
      end
      local packed = pack(parent :: vector, key, value)
      if not finite(packed.x) or not finite(packed.y) or not finite(packed.z) then
        return problem(path, 'input', 'the component must remain finite when packed into a vector')
      end
    elseif value == nil then
      for _, row in editor.rows(model) do
        local matches = #row.path == #parentPath
        for index, part in parentPath do
          matches = matches and row.path[index] == part
        end
        if matches and row.control == 'array' then
          return problem(path, 'input', 'an array entry cannot be nil; use Remove to delete it')
        end
      end
    end
  end
  if at(model.value, path) == value then
    return model, nil
  end
  return table.freeze {
    metadata = model.metadata,
    defaults = model.defaults,
    value = replace(model.value, path, 1, value),
  },
    nil
end

function editor.set(model: Model, path: Path, input: unknown): (Model?, Problem?)
  local row, failure = find(model, path, 'edit')
  if not row then
    return nil, failure
  end
  if row.optional then
    if input == nil then
      if opaque(row.metadata, row.value) then
        return problem(path, 'readonly', row.reason or 'unsetting discards opaque values')
      end
      return commit(model, path, nil)
    elseif row.control == 'optional' and input == true then
      local value, message = seed(row.metadata)
      if message then
        return problem(path, 'input', message)
      end
      return commit(model, path, value)
    end
  end
  local value, message = parse(row.metadata, input)
  if message then
    return problem(path, 'input', message)
  end
  return commit(model, path, value)
end

function editor.textProblem(input: string): string?
  if utf8.len(input) == nil then
    return 'enter valid Unicode UTF-8 or use an escaped string value'
  end
  for _, codepoint in utf8.codes(input) do
    if (codepoint >= 0xd800 and codepoint <= 0xdfff) or codepoint > 0x10ffff then
      return 'enter valid Unicode UTF-8 or use an escaped string value'
    end
    if codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f) or codepoint == 0x2028 or codepoint == 0x2029 then
      return 'enter single-line text; control characters and line separators need escapes'
    end
  end
  return nil
end

function editor.setText(model: Model, path: Path, input: string): (Model?, Problem?)
  local row, failure = find(model, path, 'edit')
  if not row then
    return nil, failure
  end
  local message = editor.textProblem(input)
  if message then
    return problem(path, 'input', message)
  end
  if row.escaped then
    local decoded, decodeFailure = decodeText(input)
    if not decoded then
      return problem(path, 'input', decodeFailure or 'enter a valid escaped string')
    end
    return editor.set(model, path, decoded)
  end
  return editor.set(model, path, input)
end

function editor.toggle(model: Model, path: Path): (Model?, Problem?)
  local value = at(model.value, path)
  return editor.set(model, path, if type(value) == 'boolean' then not value elseif value == nil then true else nil)
end

function editor.reset(model: Model, path: Path): (Model?, Problem?)
  local row, failure = find(model, path, 'reset')
  if not row then
    return nil, failure
  end
  local value = at(model.defaults, path)
  return commit(model, path, if value == nil then hydrate(row.metadata, nil, nil, {}) else value)
end

function editor.add(model: Model, path: Path, key: string?): (Model?, Problem?)
  local row, failure = find(model, path, 'collection')
  if not row then
    return nil, failure
  end
  local node = unwrap(row.metadata)
  local values = table.clone(row.value :: Raw)
  local entryKey: string | number
  if node.kind == 'array' then
    entryKey = #values + 1
  else
    if key == nil then
      return problem(path, 'key', 'a map entry needs a string key')
    end
    if values[key] ~= nil then
      return problem(path, 'key', 'the map key already exists')
    end
    entryKey = key
  end
  local value, message = seed(node.child :: schema.Metadata)
  if message then
    return problem(path, 'input', message)
  end
  if value == nil then
    return problem(path, 'input', 'a collection entry cannot be nil')
  end
  values[entryKey] = value
  return commit(model, path, table.freeze(values))
end

function editor.remove(model: Model, path: Path): (Model?, Problem?)
  if #path == 0 then
    return problem(path, 'path', 'the root cannot be removed')
  end
  local parentPath = table.clone(path) :: MutablePath
  local key = table.remove(parentPath)
  local parent, failure = find(model, parentPath, 'edit')
  if not parent then
    return nil, failure
  elseif parent.control ~= 'array' and parent.control ~= 'map' then
    return problem(path, 'path', 'the option is not a collection entry')
  end
  local values = table.clone(parent.value :: Raw)
  if values[key] == nil then
    return problem(path, 'path', 'the entry does not exist')
  end
  local row, entryFailure = find(model, path, 'remove')
  if not row then
    return nil, entryFailure
  end
  if parent.control == 'array' then
    -- The collection row proves that these erased keys are dense array indices.
    table.remove(values :: { unknown }, key :: number)
  else
    values[key] = nil
  end
  return commit(model, parentPath, table.freeze(values))
end

plain = function(value: unknown): boolean
  return type(value) == 'table' and getmetatable(value :: Raw) == nil
end

unwrap = function(metadata: schema.Metadata): (schema.Metadata, boolean)
  local node, optional = metadata, false
  while node.kind == 'default' or node.kind == 'optional' or node.kind == 'refine' do
    optional = optional or node.kind == 'optional'
    node = node.child :: schema.Metadata
  end
  return node, optional
end

opaque = function(metadata: schema.Metadata, value: unknown?, active: { [Raw]: boolean }?): boolean
  local node = unwrap(metadata)
  local container = node.kind == 'object' or node.kind == 'array' or node.kind == 'map'
  local kind = type(value)
  if
    node.readOnly
    or (container and value ~= nil and shape(node, value) == nil)
    or (not container and (kind == 'table' or kind == 'function' or kind == 'userdata' or kind == 'thread'))
  then
    return true
  end
  if plain(value) then
    local raw, seen = value :: Raw, active or {}
    if seen[raw] then
      return true
    end
    seen[raw] = true
    for key, entry in raw do
      local child = if node.fields then (if type(key) == 'string' then node.fields[key] else nil) else node.child
      if not child or opaque(child, entry, seen) then
        seen[raw] = nil
        return true
      end
    end
    seen[raw] = nil
  end
  if node.fields then
    for _, child in node.fields do
      if opaque(child) then
        return true
      end
    end
  end
  return node.child ~= nil and opaque(node.child)
end

hydrate = function(node: schema.Metadata, given: unknown, base: unknown, active: { [Raw]: boolean }): unknown
  if node.kind == 'default' then
    return hydrate(node.child :: schema.Metadata, given, if base == nil then node.value else base, active)
  elseif node.kind == 'refine' or node.kind == 'optional' then
    if node.kind == 'optional' and given == nil and base == nil then
      return nil
    end
    return hydrate(node.child :: schema.Metadata, given, base, active)
  end
  local value = if given == nil then base else given
  if node.kind ~= 'object' and node.kind ~= 'array' and node.kind ~= 'map' then
    return value
  end
  value = if node.kind == 'object' and value == nil then {} else value
  if not plain(value) then
    return value
  end
  local raw = value :: Raw
  if active[raw] then
    return value
  end
  active[raw] = true
  local result = table.clone(raw)
  if node.kind == 'object' then
    local defaults: Raw = if plain(base) then base :: Raw else {}
    for key, child in node.fields :: { [string]: schema.Metadata } do
      result[key] = hydrate(child, rawget(raw, key), rawget(defaults, key), active)
    end
  else
    for key, child in raw do
      result[key] = hydrate(node.child :: schema.Metadata, child, nil, active)
    end
  end
  active[raw] = nil
  return table.freeze(result)
end

at = function(value: unknown, path: Path): unknown
  for _, key in path do
    if plain(value) then
      value = rawget(value :: Raw, key)
    elseif typeof(value) == 'vector' and (key == 'x' or key == 'y' or key == 'z') then
      local v = value :: vector
      value = if key == 'x' then v.x elseif key == 'y' then v.y else v.z
    else
      return nil
    end
  end
  return value
end

replace = function(value: unknown, path: Path, index: number, replacement: unknown): unknown
  if index > #path then
    return replacement
  end
  local key = path[index]
  if typeof(value) == 'vector' then
    return pack(value :: vector, key, replacement :: number)
  end
  local result = table.clone(value :: Raw)
  result[key] = replace(rawget(result, key), path, index + 1, replacement)
  return table.freeze(result)
end

local function choices(metadata: schema.Metadata): { read [number]: unknown }?
  local node = unwrap(metadata)
  if node.kind == 'literal' then
    return table.freeze { node.value }
  end
  if node.kind == 'enum' then
    return node.values
  end
  if node.kind ~= 'union' or node.readOnly then
    return nil
  end
  local result: { unknown } = {}
  for _, alternative in node.alternatives :: { read [number]: schema.Metadata } do
    local values = choices(alternative)
    if not values then
      return nil
    end
    for _, value in values do
      if not table.find(result, value) then
        table.insert(result, value)
      end
    end
  end
  return table.freeze(result)
end

parse = function(metadata: schema.Metadata, input: unknown): (unknown, string?)
  local node = unwrap(metadata)
  local options = choices(node)
  if options then
    for _, option in options do
      if option == input then
        return input, nil
      end
    end
    return nil, 'select one of the declared choices'
  elseif node.kind == 'string' then
    return if type(input) == 'string' then input else nil, if type(input) == 'string' then nil else 'enter a string'
  elseif node.kind == 'number' then
    local value = if type(input) == 'string' then tonumber(input) else input
    if type(value) == 'number' and finite(value) then
      return value, nil
    end
    return nil, 'enter a finite number'
  elseif node.kind == 'boolean' then
    local values: { [unknown]: boolean } = { [true] = true, [false] = false, ['true'] = true, ['false'] = false }
    return values[input], if values[input] == nil then 'enter true or false' else nil
  end
  return nil, 'edit the individual fields instead of replacing this value'
end

seed = function(metadata: schema.Metadata, base: unknown?): (unknown, string?)
  local node = unwrap(metadata)
  if opaque(node) then
    return nil, 'code-backed values must be supplied in code'
  end
  local value = hydrate(metadata, nil, base, {})
  if opaque(node, value) then
    return nil, 'creating this option cannot discard opaque values'
  end
  if node.kind == 'object' then
    local result = table.clone((if value == nil then hydrate(node, nil, nil, {}) else value) :: Raw)
    for key, child in node.fields :: { read [string]: schema.Metadata } do
      local _, optional = unwrap(child)
      if result[key] == nil and optional then
        continue
      end
      local entry, message = seed(child, result[key])
      if message then
        return nil, key .. ': ' .. message
      end
      result[key] = entry
    end
    return table.freeze(result), nil
  elseif (node.kind == 'array' or node.kind == 'map') and value ~= nil then
    local result = table.clone(value :: Raw)
    for key, entry in result do
      local completed, message = seed(node.child :: schema.Metadata, entry)
      if message then
        return nil, tostring(key) .. ': ' .. message
      end
      result[key] = completed
    end
    return table.freeze(result), nil
  elseif value ~= nil then
    return value, nil
  end
  local options = choices(node)
  local primitives: { [string]: unknown } = {
    boolean = false,
    number = 0,
    string = '',
    vector = vector.pack(0, 0, 0),
    array = table.freeze {},
    map = table.freeze {},
  }
  value = if options then options[1] else primitives[node.kind]
  return value, if value == nil then 'this schema cannot create an editable value' else nil
end

local function keys(value: Raw): MutablePath?
  local result: MutablePath = {}
  for key in value do
    if type(key) ~= 'string' and type(key) ~= 'number' then
      return nil
    end
    if type(key) == 'number' and (key ~= key or math.abs(key) == math.huge) then
      return nil
    end
    table.insert(result, key)
  end
  table.sort(result, function(a: string | number, b: string | number): boolean
    if type(a) == 'number' then
      return type(b) ~= 'number' or a < b
    end
    return type(b) == 'string' and a < b
  end)
  return result
end

shape = function(node: schema.Metadata, value: unknown): (MutablePath?, string?)
  local entries = if plain(value) then keys(value :: Raw) else nil
  if not entries then
    return nil, 'a plain table with string or finite number keys is required'
  end
  for index, key in entries do
    if (node.kind == 'array' and key ~= index) or (node.kind == 'map' and type(key) ~= 'string') then
      return nil, 'the collection has invalid or sparse keys'
    end
  end
  return entries, nil
end

stringText = function(value: string): (string, boolean)
  if editor.textProblem(value) == nil then
    return value, false
  end
  -- Escaping bytes, not codepoints, also preserves schema-valid strings with malformed UTF-8.
  local parts: { string } = {}
  local escapes: { [number]: string } = { [92] = '\\\\', [10] = '\\n', [13] = '\\r', [9] = '\\t' }
  for index = 1, #value do
    local byte = string.byte(value, index)
    parts[index] = escapes[byte]
      or (if byte >= 0x20 and byte <= 0x7e then string.char(byte) else string.format('\\x%02X', byte))
  end
  return table.concat(parts), true
end

decodeText = function(input: string): (string?, string?)
  local parts: { string } = {}
  local index = 1
  local escapes: { [string]: string } = { ['\\'] = '\\', n = '\n', r = '\r', t = '\t' }
  while index <= #input do
    local char = string.sub(input, index, index)
    if char ~= '\\' then
      table.insert(parts, char)
      index += 1
      continue
    end
    local escape = string.sub(input, index + 1, index + 1)
    local decoded = escapes[escape]
    if decoded then
      table.insert(parts, decoded)
      index += 2
    elseif escape == 'x' then
      local digits = string.sub(input, index + 2, index + 3)
      if #digits ~= 2 or not string.match(digits, '^%x%x$') then
        return nil, 'a byte escape needs exactly two hex digits: \\xHH'
      end
      table.insert(parts, string.char(tonumber(digits, 16) :: number))
      index += 4
    else
      return nil, 'use only \\\\, \\n, \\r, \\t, or \\xHH escapes'
    end
  end
  return table.concat(parts), nil
end

local function pathText(path: Path): string
  local parts: { string } = {}
  for _, key in path do
    table.insert(parts, if type(key) == 'number' then '[' .. tostring(key) .. ']' else string.format('%q', key))
  end
  return if #parts == 0 then '<root>' else table.concat(parts, '.')
end

local function childPath(path: Path, key: string | number): Path
  local result = table.clone(path) :: MutablePath
  table.insert(result, key)
  return result
end

local unknownMetadata: schema.Metadata = table.freeze {
  kind = 'custom' :: 'custom',
  readOnly = true,
  merge = 'replace' :: 'replace',
  value = nil,
  description = 'the field is not declared in the schema',
}

local numberMetadata = schema.number().inspect()
flatten = function(
  metadata: schema.Metadata,
  value: unknown,
  path: Path,
  rows: { Row },
  active: { [Raw]: boolean },
  defaults: unknown,
  collectionEntry: boolean
): ()
  local node, optional = unwrap(metadata)
  local control: Control = 'readonly'
  local reason: string? = nil
  local options = choices(node)
  local container = node.kind == 'object' or node.kind == 'array' or node.kind == 'map'
  local entries, shapeReason = shape(node, value)
  if node.readOnly then
    reason = if metadata == unknownMetadata
      then metadata.description
      else 'callbacks and custom values are edited in code'
  elseif optional and value == nil then
    control = 'optional'
  elseif container then
    if not entries then
      reason = shapeReason
    elseif active[value :: Raw] then
      reason = 'recursive containers are read-only'
    else
      control = if node.kind == 'object' then 'group' else node.kind :: 'array' | 'map'
    end
  elseif options then
    control = 'choice'
  elseif node.kind == 'union' then
    reason = 'only enums and unions of literals have a generic choice editor'
  elseif node.kind == 'vector' then
    control = if typeof(value) == 'vector' then 'group' else 'readonly'
    reason = if control == 'readonly' then 'a native vector is required' else nil
  elseif node.kind == 'number' or node.kind == 'string' or node.kind == 'boolean' then
    control = node.kind
  end
  local blocked = opaque(metadata, value)
  if blocked and not container then
    control = 'readonly'
  end
  local readOnly = control == 'readonly'
  reason = reason or (if blocked then 'replacing this option could discard code-backed or undeclared values' else nil)
  local collection = control == 'array' or control == 'map'
  local entry, seedFailure = nil :: unknown, nil :: string?
  if collection then
    entry, seedFailure = seed(node.child :: schema.Metadata)
  end
  local defaultValue = hydrate(metadata, nil, nil, {})
  local resetValue = at(defaults, path)
  resetValue = if resetValue == nil then defaultValue else resetValue
  local parent = rows[#rows]
  if collectionEntry then
    for index = #rows, 1, -1 do
      local candidate = rows[index]
      if #candidate.path == #path - 1 then
        parent = candidate
        break
      end
    end
  end
  local arrayEntry = collectionEntry and parent ~= nil and parent.control == 'array'
  local text = if value == nil
    then '<unset>'
    elseif container or readOnly then '<' .. node.kind .. '>'
    else tostring(value)
  local escaped = false
  if control == 'string' and type(value) == 'string' then
    text, escaped = stringText(value)
  end
  local row: Row = table.freeze {
    path = table.freeze(table.clone(path)),
    label = metadata.label or pathText(path),
    description = metadata.description or node.description,
    metadata = metadata,
    control = control,
    value = value,
    text = text,
    escaped = escaped,
    choices = options,
    optional = optional,
    readOnly = readOnly,
    reason = reason,
    canReset = not readOnly
      and not blocked
      and (optional or resetValue ~= nil)
      and (not arrayEntry or resetValue ~= nil),
    canAdd = collection and seedFailure == nil and entry ~= nil and not opaque(node.child :: schema.Metadata, entry),
    canRemove = collectionEntry and not blocked,
  }
  table.insert(rows, row)
  if readOnly or value == nil then
    return
  end
  if node.kind == 'vector' then
    for _, key in { 'x', 'y', 'z' } do
      local component: Path = { key }
      local nextPath = childPath(path, key)
      flatten(numberMetadata, at(value, component), nextPath, rows, active, defaults, false)
    end
  elseif container then
    local raw = value :: Raw
    active[raw] = true
    local children: { [string | number]: schema.Metadata } = {}
    if node.fields then
      for key, child in node.fields do
        children[key] = child
      end
    end
    for _, key in entries :: Path do
      children[key] = children[key] or node.child or unknownMetadata
    end
    for _, key in keys(children :: Raw) :: Path do
      local nextPath = childPath(path, key)
      flatten(children[key], rawget(raw, key), nextPath, rows, active, defaults, collection)
    end
    active[raw] = nil
  end
end

return table.freeze(editor)

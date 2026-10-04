-- Validates keyboard rows and layers, which replace defaults wholesale, and reports errors by option path.

local lunette = require '@lunette'
local keyboard = require '@lunette-contracts/keyboard'

local validation = {}

export type Checked = {
  read rows: { keyboard.KeyRow },
  read layers: { [string]: { keyboard.KeyRow } },
  read modifierKeys: { [number]: string },
  read locks: { string },
}

type Raw = { [unknown]: unknown }

local ACTION_FIELDS: { [string]: { [string]: string } } = {
  hide = {},
  layer = { layer = 'string' },
  text = { text = 'string' },
  chord = { code = 'number', modifiers = 'table' },
  custom = { name = 'string' },
}

type Context = {
  read name: string,
  read modifiers: { [string]: boolean },
  read layers: { [string]: boolean },
}

local function fail(name: string, path: string, problem: string): never
  error(string.format('plugin %s: option %s %s', name, path, problem), 0)
end

local function isCode(value: unknown): boolean
  return type(value) == 'number' and value >= 0 and value % 1 == 0
end

local function checkModifier(context: Context, path: string, modifier: unknown): ()
  if type(modifier) ~= 'string' or not context.modifiers[modifier] then
    fail(context.name, path, 'is a modifier name, not ' .. tostring(modifier))
  end
end

local function checkAction(context: Context, path: string, action: unknown): ()
  if type(action) ~= 'table' then
    fail(context.name, path, 'is an action table, not a ' .. type(action))
  end
  local raw = action :: Raw
  local kind: string = if type(raw.kind) == 'string' then raw.kind else ''
  local fields = ACTION_FIELDS[kind]
  if fields == nil then
    fail(context.name, path .. '.kind', 'is hide, layer, text, chord, or custom, not ' .. tostring(raw.kind))
  end
  for field, value in raw do
    local name = tostring(field)
    if name ~= 'kind' then
      local wanted = fields[name]
      if wanted == nil then
        fail(context.name, path, 'has an unknown field ' .. name .. ' for a ' .. kind .. ' action')
      end
      if type(value) ~= wanted then
        fail(context.name, path .. '.' .. name, 'is a ' .. wanted .. ', not a ' .. type(value))
      end
    end
  end
  for field, _ in fields do
    if raw[field] == nil then
      fail(context.name, path, 'is a ' .. kind .. ' action without its ' .. field)
    end
  end
  if kind == 'layer' and not context.layers[raw.layer :: string] then
    fail(context.name, path .. '.layer', 'names no layer: ' .. tostring(raw.layer))
  elseif kind == 'chord' then
    if not isCode(raw.code) then
      fail(context.name, path .. '.code', 'is an evdev code, not ' .. tostring(raw.code))
    end
    for index, modifier in ipairs(raw.modifiers :: { unknown }) do
      checkModifier(context, string.format('%s.modifiers[%d]', path, index), modifier)
    end
  end
end

local KEY_FIELDS: { [string]: boolean } = {
  code = true,
  action = true,
  label = true,
  width = true,
  height = true,
  x = true,
}

local function checkKey(context: Context, path: string, key: unknown): ()
  if type(key) ~= 'table' then
    fail(context.name, path, 'is a key table, not a ' .. type(key))
  end
  local raw = key :: Raw
  for field, _ in raw do
    if type(field) ~= 'string' or not KEY_FIELDS[field] then
      fail(
        context.name,
        path,
        'has an unknown field ' .. tostring(field) .. '; the fields are code, action, label, width, height, and x'
      )
    end
  end
  if raw.code ~= nil and not isCode(raw.code) then
    fail(context.name, path .. '.code', 'is an evdev code, not ' .. tostring(raw.code))
  end
  if raw.code ~= nil and raw.action ~= nil then
    fail(context.name, path, 'has a code and an action; a key has one or the other')
  end
  if raw.label ~= nil and type(raw.label) ~= 'string' then
    fail(context.name, path .. '.label', 'is a string, not a ' .. type(raw.label))
  end
  for _, field in ipairs { 'width', 'height' } do
    local value = raw[field]
    if value ~= nil and not (type(value) == 'number' and value > 0 and value < math.huge) then
      fail(context.name, path .. '.' .. field, 'is a positive number, not ' .. tostring(value))
    end
  end
  local x = raw.x
  if x ~= nil and not (type(x) == 'number' and x >= 0 and x < math.huge) then
    fail(context.name, path .. '.x', 'is a number of key units no less than zero, not ' .. tostring(x))
  end
  if raw.action ~= nil then
    checkAction(context, path .. '.action', raw.action)
  end
end

local function checkRows(context: Context, path: string, rows: unknown): ()
  if type(rows) ~= 'table' then
    fail(context.name, path, 'is a list of rows, not a ' .. type(rows))
  end
  for index, row in ipairs(rows :: { unknown }) do
    local rowPath = string.format('%s[%d]', path, index)
    if type(row) ~= 'table' then
      fail(context.name, rowPath, 'is a list of keys, not a ' .. type(row))
    end
    for column, key in ipairs(row :: { unknown }) do
      checkKey(context, string.format('%s[%d]', rowPath, column), key)
    end
  end
end

function validation.settings(settings: Checked, name: string): ()
  local modifiers: { [string]: boolean } = {}
  for _, modifier in ipairs(lunette.modifierNames()) do
    modifiers[modifier] = true
  end
  local layers: { [string]: boolean } = { base = true }
  for layer, _ in settings.layers do
    if type(layer) ~= 'string' or layer == '' or layer == 'base' then
      fail(name, 'layers', 'names a layer with a non-empty string other than base, not ' .. tostring(layer))
    end
    layers[layer] = true
  end
  local context = { name = name, modifiers = modifiers, layers = layers }
  checkRows(context, 'rows', settings.rows)
  for layer, rows in settings.layers do
    checkRows(context, 'layers.' .. layer, rows)
  end
  for code, modifier in settings.modifierKeys do
    if not isCode(code) then
      fail(name, 'modifierKeys', 'is keyed by evdev codes, not ' .. tostring(code))
    end
    checkModifier(context, string.format('modifierKeys[%d]', code :: number), modifier)
  end
  for index, modifier in ipairs(settings.locks) do
    checkModifier(context, string.format('locks[%d]', index), modifier)
  end
end

return validation

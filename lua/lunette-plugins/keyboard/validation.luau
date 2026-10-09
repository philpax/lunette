-- Checks what the keyboard schema cannot express: references between rows, layers, and modifier names.

local lunette = require '@lunette'
local keyboard = require '@lunette-contracts/keyboard'

local validation = {}

export type Checked = {
  read rows: { read [number]: keyboard.KeyRow },
  read layers: { read [string]: { read [number]: keyboard.KeyRow } },
  read modifierKeys: { read [number]: string },
  read locks: { read [number]: string },
}

type Context = {
  read modifiers: { [string]: boolean },
  read layers: { [string]: boolean },
}

local function fail(path: string, problem: string): never
  error(string.format('option %s %s', path, problem), 0)
end

local function checkModifier(context: Context, path: string, modifier: string): ()
  if not context.modifiers[modifier] then
    fail(path, 'is a modifier name, not ' .. modifier)
  end
end

local function checkRows(context: Context, path: string, rows: { read [number]: keyboard.KeyRow }): ()
  for index, row in rows do
    for column, key in row do
      local keyPath = string.format('%s[%d][%d]', path, index, column)
      local action = key.action
      if key.code ~= nil and action ~= nil then
        fail(keyPath, 'has a code and an action; a key has one or the other')
      end
      if action and action.kind == 'layer' and not context.layers[action.layer] then
        fail(keyPath .. '.action.layer', 'names no layer: ' .. action.layer)
      elseif action and action.kind == 'chord' then
        for position, modifier in action.modifiers do
          checkModifier(context, string.format('%s.action.modifiers[%d]', keyPath, position), modifier)
        end
      end
    end
  end
end

function validation.settings(settings: Checked): ()
  local modifiers: { [string]: boolean } = {}
  for _, modifier in ipairs(lunette.modifierNames()) do
    modifiers[modifier] = true
  end
  local layers: { [string]: boolean } = { base = true }
  for layer, _ in settings.layers do
    if layer == '' or layer == 'base' then
      fail('layers', 'names a layer with a non-empty string other than base, not ' .. layer)
    end
    layers[layer] = true
  end
  local context = { modifiers = modifiers, layers = layers }
  checkRows(context, 'rows', settings.rows)
  for layer, rows in settings.layers do
    checkRows(context, 'layers.' .. layer, rows)
  end
  for code, modifier in settings.modifierKeys do
    checkModifier(context, string.format('modifierKeys[%d]', code), modifier)
  end
  for index, modifier in settings.locks do
    checkModifier(context, string.format('locks[%d]', index), modifier)
  end
end

return validation

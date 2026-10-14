-- Checks what the keyboard schema cannot express: references between rows and layers.

local keyboard = require '@lunette-contracts/keyboard'

local validation = {}

export type Checked = {
  read rows: { read [number]: keyboard.KeyRow },
  read layers: { read [string]: { read [number]: keyboard.KeyRow } },
}

local function fail(path: string, problem: string): never
  error(string.format('option %s %s', path, problem), 0)
end

local function checkRows(layers: { [string]: boolean }, path: string, rows: { read [number]: keyboard.KeyRow }): ()
  for index, row in rows do
    for column, key in row do
      local keyPath = string.format('%s[%d][%d]', path, index, column)
      local action = key.action
      if key.code ~= nil and action ~= nil then
        fail(keyPath, 'has a code and an action; a key has one or the other')
      end
      if action and action.kind == 'layer' and not layers[action.layer] then
        fail(keyPath .. '.action.layer', 'names no layer: ' .. action.layer)
      end
    end
  end
end

function validation.settings(settings: Checked): ()
  local layers: { [string]: boolean } = { base = true }
  for layer, _ in settings.layers do
    if layer == '' or layer == 'base' then
      fail('layers', 'names a layer with a non-empty string other than base, not ' .. layer)
    end
    layers[layer] = true
  end
  checkRows(layers, 'rows', settings.rows)
  for layer, rows in settings.layers do
    checkRows(layers, 'layers.' .. layer, rows)
  end
end

return validation

-- Covers the built-in provider schemas exposed to configuration management.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local laser = require '@lunette-plugins/laser'
local keyboard = require '@lunette-plugins/keyboard'
local arrangement = require '@lunette-plugins/arrangement'
local arc = require '@lunette-plugins/layout/arc'

local test = testing.suite()

local providers = {
  require '@lunette-plugins/adoption',
  require '@lunette-plugins/bindings',
  require '@lunette-plugins/drops',
  require '@lunette-plugins/errors',
  require '@lunette-plugins/focus',
  require '@lunette-plugins/frame',
  require '@lunette-plugins/interaction',
  keyboard,
  laser,
  require '@lunette-plugins/layouts',
  require '@lunette-plugins/pacing',
  require '@lunette-plugins/panels',
  require '@lunette-plugins/placement',
  require '@lunette-plugins/rules',
  require '@lunette-plugins/scale',
  require '@lunette-plugins/surfaces',
  require '@lunette-plugins/tags',
  arc,
  { definition = arrangement.factory() },
}

test('every built-in provider exposes frozen metadata and a side-effect-free configuration resolver', function()
  for _, provider in providers do
    local definition = provider.definition
    local metadata = plugin.definitionSchema(definition)
    expect.truthy(metadata and table.isfrozen(metadata), definition.name .. ' metadata')
    expect.equal(metadata.kind, 'default', definition.name .. ' bound defaults')
    expect.equal(metadata.child.kind, 'object', definition.name .. ' object shape')
    local settings = definition.resolve(nil)
    expect.truthy(table.isfrozen(settings), definition.name .. ' settings')
    expect.raises(function()
      definition.resolve { undeclared = true }
    end, 'is not a declared field', definition.name .. ' closed shape')
    expect.raises(function()
      definition.resolve(false)
    end, 'is a table', definition.name .. ' invalid root')
  end
end)

test('defined defaults merge nested fields while mapping lists replace and callbacks retain identity', function()
  local draw = function() end
  local definition = laser.define { name = 'schema-laser', style = { length = 3 }, draw = draw }
  local resolved = definition.resolve { style = { color = { 1, 0, 0, 1 } }, buttons = {} }
  expect.equal(resolved.style.length, 3, 'defined length')
  expect.equal(resolved.style.cursorRadius, 0.006, 'cursor geometry retains the non-theme default')
  expect.equal(#resolved.buttons, 0, 'empty mapping list replaces')
  expect.equal(resolved.draw, draw, 'callback identity')
  expect.equal(definition.schema.value.style.length, 3, 'bound default metadata')
  expect.equal(definition.schema.child.fields.draw.readOnly, true, 'callback metadata')
  expect.falsy(laser.definition.schema.child.fields.buttons.readOnly, 'editable mapping list')
end)

test('keyboard rows and layers replace and retain structured editable metadata', function()
  local definition = keyboard.define { layers = { symbols = { { { action = { kind = 'text', text = '#' } } } } } }
  local settings = definition.resolve { rows = {}, layers = {}, style = { gap = 0.01 } }
  expect.equal(#settings.rows, 0, 'rows replace')
  expect.equal(next(settings.layers), nil, 'empty map replaces')
  expect.equal(settings.style.gap, 0.01, 'style override')
  expect.equal(settings.style.keyUnit, 0.028, 'key units retain the non-theme structural default')
  local fields = definition.schema.child.fields
  expect.equal(fields.rows.child.kind, 'array', 'rows array')
  expect.equal(fields.rows.child.child.child.kind, 'object', 'key object')
  expect.falsy(fields.rows.readOnly, 'editable rows')
  expect.equal(fields.layers.child.kind, 'map', 'layers map')
  expect.equal(fields.modifierKeys.readOnly, true, 'numeric-key mapping is code-backed')
end)

test('arrangement factories and named arc definitions expose the same defaults used at activation', function()
  local first, second = arrangement.factory(), arrangement.factory()
  expect.truthy(first ~= second, 'factories create independent definitions')
  expect.equal(first.resolve(nil).file, arrangement.FILE, 'arrangement file')
  expect.equal(first.resolve(nil).keyFor, arrangement.defaultKey, 'arrangement callback')
  local named = arc.define { name = 'schema-arc', tuning = { radius = 3 } }
  expect.equal(named.resolve({ tuning = { gap = 0.2 } }).tuning.radius, 3, 'arc defined radius')
  expect.equal(named.schema.value.tuning.radius, 3, 'arc bound metadata')
  expect.raises(function()
    named.resolve { tuning = { radius = 0 } }
  end, 'positive number', 'arc radius constraint')
end)

test('keyboard custom configuration retains identity through defaults, overrides, and repeated resolution', function()
  local keys = require '@lunette-contracts/keys'
  local defaults = keyboard.definition.resolve(nil)
  expect.equal(defaults.modifierKeys, keys.MODIFIER_KEYS, 'default custom identity')
  local modifiers = { [42] = 'shift' }
  local definition = keyboard.define { modifierKeys = modifiers }
  expect.equal(definition.schema.value.modifierKeys, modifiers, 'defined custom identity')
  local settings = definition.resolve(nil)
  expect.equal(settings.modifierKeys, modifiers, 'resolved custom identity')
  expect.equal(definition.resolve(settings).modifierKeys, modifiers, 'repeated custom identity')
  expect.falsy(table.isfrozen(modifiers), 'caller custom table is not frozen')
  modifiers[29] = 'control'
  expect.equal(definition.resolve(nil).modifierKeys[29], 'control', 'caller customization remains available')
  modifiers[29] = 'hyper'
  expect.raises(function()
    definition.resolve(nil)
  end, 'modifier name', 'custom values are checked again after customization')
  modifiers[29] = 'control'
  for _, invalid in { { [math.huge] = 'shift' }, { [1.5] = 'shift' }, { [42] = true }, setmetatable({}, {}) } do
    expect.raises(function()
      keyboard.define { modifierKeys = invalid }
    end, 'modifierKeys', 'invalid numeric-key custom mapping')
  end
end)

return test

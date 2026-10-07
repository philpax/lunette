local testing = require '@testing'
local expect = testing.expect
local desktop = require '@lunette-desktop'
local test = testing.suite()

local function configured(entries, id)
  for _, entry in entries do
    if entry.id == id then
      return entry
    end
  end
  error('the desktop has no ' .. id .. ' entry')
end

test('removed session binding settings report migration', function()
  expect.raises(function()
    desktop.compose { settings = { bindings = {} } }
  end, 'settings.bindings.*removed.*wrist menu')
  for _, field in { 'hand', 'size', 'offset', 'haptic' } do
    local values = { hand = 'right', size = 0.15, offset = vector.pack(0, 0, 0), haptic = {} }
    expect.raises(function()
      desktop.compose { settings = { wristKeyboard = { [field] = values[field] } } }
    end, 'wristKeyboard.' .. field .. '.*settings.menu')
  end
  expect.raises(function()
    desktop.compose { workspaces = { workspaces = { { name = 'main', key = '1' } } } }
  end, 'workspaces.*key.*removed.*menu')
  expect.raises(function()
    desktop.compose { workspaces = { modifiers = { 'logo' } } }
  end, 'workspaces.*modifiers.*removed.*menu')
  expect.raises(function()
    desktop.compose { settings = { manager = { toggleKey = 'f10' } } }
  end, 'manager.*toggleKey.*removed.*Plugins')
end)

test('desktop defaults include the menu recovery path without a physical session binding entry', function()
  local entries = desktop.entries()
  configured(entries, 'ui')
  configured(entries, 'menu')
  configured(entries, 'desktop/menu')
  configured(entries, 'desktop/actions')
  configured(entries, 'desktop/keyboard')
  for _, entry in entries do
    expect.truthy(entry.id ~= 'desktop/bindings', 'the default composition does not register a reload chord')
  end
  local changed = desktop.compose {
    settings = { menu = { hand = 'right', size = 0.15 }, wristKeyboard = { placement = { distance = 0.7 } } },
  }
  expect.equal(configured(changed, 'desktop/menu').config.hand, 'right')
  expect.equal(configured(changed, 'desktop/keyboard').config.placement.distance, 0.7)
end)

return test

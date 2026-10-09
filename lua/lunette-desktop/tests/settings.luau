-- Desktop settings, keyed by entry id, expand into one configuration patch per entry.
local testing = require '@testing'
local expect = testing.expect
local desktop = require '@lunette-desktop'
local panelsContract = require '@lunette-contracts/panels'
local tagsContract = require '@lunette-contracts/tags'

local test = testing.suite()

local function sameValue(actual, expected, where)
  if type(expected) ~= 'table' then
    expect.equal(actual, expected, where)
    return
  end
  expect.equal(type(actual), 'table', where)
  for key, value in pairs(expected) do
    sameValue(actual[key], value, where .. '.' .. tostring(key))
  end
  for key, _ in pairs(actual) do
    expect.truthy(expected[key] ~= nil, where .. ' has no extra field ' .. tostring(key))
  end
end

local function sameEntries(actual, expected)
  expect.equal(#actual, #expected, 'the entry count')
  for index, entry in ipairs(expected) do
    sameValue(actual[index], entry, 'entry ' .. index)
  end
end

local CONFIGS = {
  laser = { aim = { enabled = false } },
  interaction = { tuning = { reach = 0.5 } },
  ['layout/arc'] = { tuning = { radius = 2 } },
  ['desktop/theme'] = { preset = 'light' },
  ['desktop/menu'] = { hand = 'right', size = 0.14 },
  ['desktop/decorations'] = { style = { barColor = { 0.3, 0.12, 0.2, 0.95 } } },
  ['desktop/arrange'] = { layout = 'grid' },
  ['desktop/persistence'] = { file = 'desktop.state' },
  ['desktop/keyboard'] = { placement = { distance = 0.45 } },
  ['desktop/rules'] = { rules = { { match = { appId = 'mail' }, properties = { tags = { 'mail' } } } } },
  ['desktop/hint'] = { textHeight = 0.1 },
  ['desktop/errors'] = { width = 1.2 },
  ['desktop/workspaces'] = { names = { 'work' } },
}

test('each setting is the configuration patch for the entry of its key', function()
  local patches = {}
  for id, config in pairs(CONFIGS) do
    patches[#patches + 1] = { id = id, config = config }
  end
  sameEntries(desktop.compose { settings = CONFIGS }, desktop.compose { patches = patches })
end)

test('a workspaces patch puts an adopted window in the selected workspace', function()
  local session = testing.boot(desktop.compose {
    patches = { { id = 'desktop/workspaces', config = { names = { 'work', 'web' } } } },
  })
  local native = session.native
  local panels = session:observe(panelsContract.capability).service
  local tags = session:observe(tagsContract.capability).service
  local window = native.newWindow(1)
  native.events.windows = { window }
  native.emit('onWindowOpened', { window = window })
  local panel = assert(panels:forSource(window))
  expect.truthy(assert(tags:find 'work'):has(panel), 'the window joins the selected workspace')
  expect.falsy(panel.hidden, 'the window is shown')
  session:close()
end)

return test

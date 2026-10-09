-- Typed desktop settings expand into the existing independent entries and preserve raw customization.
local testing = require '@testing'
local expect = testing.expect
local desktop = require '@lunette-desktop'

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
  menu = { hand = 'right', size = 0.14 },
  decorations = { style = { barColor = { 0.3, 0.12, 0.2, 0.95 } } },
  arrange = { layout = 'grid', options = { grid = { columns = 3 } } },
  persistence = { file = 'desktop.state' },
  keyboardDisplay = { placement = { distance = 0.45 } },
  rules = { rules = { { match = { appId = 'mail' }, properties = { tags = { 'mail' } } } } },
  monitors = { select = { 'fixture-output' } },
  hint = { text = 'fixture hint' },
  errors = { width = 1.2 },
  pointing = { laser = { name = 'fixture-pointer', style = { length = 2.5 }, tuning = { reach = 0.5 } } },
  pacing = { pauseMonitors = false },
  workspaces = { workspaces = { { name = 'work' } } },
  adoption = { tags = { 'work' } },
}

local RAW_PATCHES = {
  { id = 'desktop/menu', config = CONFIGS.menu },
  { id = 'desktop/decorations', config = CONFIGS.decorations },
  { id = 'desktop/arrange', config = CONFIGS.arrange },
  { id = 'desktop/persistence', config = CONFIGS.persistence },
  { id = 'desktop/keyboard', config = CONFIGS.keyboardDisplay },
  { id = 'desktop/rules', config = CONFIGS.rules },
  { id = 'desktop/monitors', config = CONFIGS.monitors },
  { id = 'desktop/hint', config = CONFIGS.hint },
  { id = 'desktop/errors', config = CONFIGS.errors },
  { id = 'desktop/pointing', config = CONFIGS.pointing },
  { id = 'desktop/pacing', config = CONFIGS.pacing },
  { id = 'desktop/workspaces', config = CONFIGS.workspaces },
  { id = 'desktop/adoption', config = CONFIGS.adoption },
}

test('typed settings are equivalent to raw patches, and workspaces adopt into the first workspace', function()
  sameEntries(desktop.compose { settings = CONFIGS }, desktop.compose { patches = RAW_PATCHES })
  local workspaces = { workspaces = { { name = 'main' }, { name = 'side' } } }
  sameEntries(
    desktop.compose { settings = { workspaces = workspaces } },
    desktop.compose {
      patches = {
        { id = 'desktop/workspaces', config = workspaces },
        { id = 'desktop/adoption', config = { tags = { 'main' } } },
      },
    }
  )
end)

return test

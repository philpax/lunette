-- Desktop settings, keyed by entry id, expand into one configuration patch per entry.
local testing = require '@testing'
local expect = testing.expect
local desktop = require '@lunette-desktop'
local settings = require '@lunette-desktop/settings'
local panelsContract = require '@lunette-contracts/panels'
local tagsContract = require '@lunette-contracts/tags'

type ConfigValue = boolean | number | string | vector | { [string | number]: ConfigValue }
type Entries = typeof(desktop.compose())

local test = testing.suite()

local function sameValue(actual: unknown, expected: unknown, where: string)
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

local function sameEntries(actual: Entries, expected: Entries)
  expect.equal(#actual, #expected, 'the entry count')
  for index, entry in ipairs(expected) do
    sameValue(actual[index], entry, 'entry ' .. index)
  end
end

local CONFIGS = {
  laser = { aim = { enabled = false } },
  audio = {},
  ['audio-analysis'] = {},
  ['desktop/backdrop'] = { enabled = false },
  interaction = { tuning = { reach = 0.5 } },
  ['layout/arc'] = { tuning = { radius = 2 } },
  ['desktop/theme'] = { preset = 'light' },
  ['desktop/menu'] = { hand = 'right', size = 0.14 },
  ['desktop/decorations'] = { height = 0.045 },
  ['desktop/arrange'] = { layout = 'grid' },
  ['desktop/persistence'] = { file = 'desktop.state' },
  ['desktop/keyboard'] = { placement = { distance = 0.45 } },
  ['desktop/rules'] = { rules = { { match = { appId = 'mail' }, properties = { tags = { 'mail' } } } } },
  ['desktop/hint'] = { text = 'fixture hint' },
  ['desktop/errors'] = { width = 1.2 },
  ['desktop/workspaces'] = { names = { 'work' } },
}

test('desktop_backdrop_composition_and_settings', function()
  local expected = {
    'frame',
    'theme',
    'themes',
    'theme/standard',
    'theme/arcade',
    'surfaces',
    'panels',
    'drops',
    'focus',
    'bindings',
    'interaction',
    'laser',
    'keyboard',
    'ui-host',
    'ui-standard',
    'notifications',
    'accessibility',
    'menu',
    'desktop/theme',
    'tags',
    'rules',
    'placement',
    'adoption',
    'layouts',
    'layout/arc',
    'errors',
    'pacing',
    'scale',
    'audio',
    'audio-analysis',
    'desktop/render',
    'desktop/hint',
    'desktop/decorations',
    'desktop/pointing',
    'desktop/mouse-pointer',
    'desktop/simulator',
    'desktop/input',
    'desktop/keyboard',
    'desktop/menu',
    'desktop/actions',
    'desktop/errors',
    'diagnostics/recovery',
    'desktop/workspaces',
    'desktop/monitors',
    'desktop/rules',
    'desktop/persistence',
    'desktop/arrange',
    'desktop/adoption',
    'desktop/pacing',
    'desktop/scale',
    'desktop/backdrop',
    'desktop/manager',
    'desktop/accessibility',
  }
  local entries = desktop.compose()
  expect.equal(#entries, #expected, 'the default entry count')
  for index, id in ipairs(expected) do
    expect.equal(entries[index].id, id, 'the default entry ' .. index)
  end

  local parsed = settings.schema.parse({
    audio = {},
    ['audio-analysis'] = {},
    ['desktop/backdrop'] = { enabled = false },
  }, 'desktop settings')
  expect.falsy(parsed['desktop/backdrop'].enabled, 'the backdrop setting is parsed')
end)

test('each setting is the configuration patch for the entry of its key', function()
  local patches: { { id: string, config: { [string]: ConfigValue } } } = {}
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

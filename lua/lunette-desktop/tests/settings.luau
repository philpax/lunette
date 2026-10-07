-- Typed desktop settings expand into the existing independent entries and preserve raw customization.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local desktop = require '@lunette-desktop'
local workspaces = require '@lunette-plugins/desktop/workspaces'
local panelsContract = require '@lunette-contracts/panels'
local tagsContract = require '@lunette-contracts/tags'
local menuContract = require '@lunette-contracts/menu'

local test = testing.suite()

local function entry(entries, id)
  for _, candidate in entries do
    if candidate.id == id then
      return candidate
    end
  end
  error('missing entry ' .. id)
end

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
  wristKeyboard = { placement = { distance = 0.45 } },
  rules = { rules = { { match = { appId = 'mail' }, properties = { tags = { 'mail' } } } } },
  monitors = { select = { 'fixture-output' } },
  hint = { text = 'fixture hint' },
  errors = { width = 1.2 },
  pointing = { laser = { name = 'fixture-pointer', style = { length = 2.5 }, tuning = { reach = 0.5 } } },
  pacing = { pauseMonitors = false },
  workspace = { name = 'work' },
  adoption = { tags = { 'work' } },
}

local RAW_PATCHES = {
  { id = 'desktop/menu', config = CONFIGS.menu },
  { id = 'desktop/decorations', config = CONFIGS.decorations },
  { id = 'desktop/arrange', config = CONFIGS.arrange },
  { id = 'desktop/persistence', config = CONFIGS.persistence },
  { id = 'desktop/keyboard', config = CONFIGS.wristKeyboard },
  { id = 'desktop/rules', config = CONFIGS.rules },
  { id = 'desktop/monitors', config = CONFIGS.monitors },
  { id = 'desktop/hint', config = CONFIGS.hint },
  { id = 'desktop/errors', config = CONFIGS.errors },
  { id = 'desktop/pointing', config = CONFIGS.pointing },
  { id = 'desktop/pacing', config = CONFIGS.pacing },
  { id = 'desktop/workspace', config = CONFIGS.workspace },
  { id = 'desktop/adoption', config = CONFIGS.adoption },
}

local WORKSPACES = {
  workspaces = { { name = 'main' }, { name = 'side' } },
}

local function workspacePatches(config, initial)
  return {
    { id = 'desktop/workspace', config = { name = initial } },
    { id = 'desktop/adoption', config = { tags = { initial } } },
    { insert = { id = 'desktop/workspaces', definition = workspaces, config = config }, before = 'desktop/adoption' },
  }
end

test('typed settings are equivalent to raw patches, without changing defaults or factory sources', function()
  local actual = desktop.compose { settings = CONFIGS }
  sameEntries(actual, desktop.compose { patches = RAW_PATCHES })
  sameEntries(desktop.compose { settings = {} }, desktop.entries())
  for index, entry in ipairs(desktop.entries()) do
    expect.equal(actual[index].definition, entry.definition, 'the original definition of ' .. entry.id)
    expect.equal(actual[index].factory, entry.factory, 'the original factory of ' .. entry.id)
    expect.equal(entry.config, nil, 'the default config is unchanged')
  end
  expect.falsy(table.isfrozen(CONFIGS.decorations.style), 'the caller still owns its config')
  expect.truthy(table.isfrozen(entry(actual, 'desktop/decorations').config.style), 'composed config is frozen')
end)

test('settings merge with entry config and coexist with independent provider patches', function()
  local entries = plugin.compose(desktop.entries(), {
    { id = 'desktop/decorations', config = { style = { barHeight = 0.05 } } },
  })
  local patches = { { id = 'keyboard', definition = require('@lunette-plugins/keyboard').definition } }
  local actual =
    desktop.compose { entries = entries, settings = { decorations = CONFIGS.decorations }, patches = patches }
  local expected = plugin.compose(entries, {
    RAW_PATCHES[2],
    patches[1],
  })
  sameEntries(actual, expected)
  expect.equal(
    entry(actual, 'desktop/decorations').config.style.barHeight,
    0.05,
    'the configured entry retains the unpatched style'
  )
  sameEntries(desktop.compose { entries = {}, settings = {} }, {})
  expect.raises(function()
    desktop.compose { entries = {}, settings = { menu = {} } }
  end, 'which is not an entry')
end)

test('workspaces expand into three raw patches with a separate consumer before adoption', function()
  local actual = desktop.compose { workspaces = WORKSPACES }
  sameEntries(actual, desktop.compose { patches = workspacePatches(WORKSPACES, 'main') })
  expect.equal(#actual, #desktop.entries() + 1, 'only the optional consumer is added')
  for index, entry in ipairs(actual) do
    if entry.id == 'desktop/workspaces' then
      expect.equal(actual[index + 1].id, 'desktop/adoption', 'workspace placement listeners precede boot adoption')
    end
  end
  sameEntries(desktop.compose { workspaces = {} }, desktop.compose { patches = workspacePatches({}, 'main') })
end)

test('unknown sections, malformed lists, and shorthand collisions raise before callbacks bind', function()
  local load = lovr.load
  for _, case in ipairs {
    { options = { settings = { keyboard = {} } }, message = 'the settings: unknown field keyboard' },
    { options = { settings = { demoTerminal = {} } }, message = 'the settings: unknown field demoTerminal' },
    { options = { workspaces = { names = {} } }, message = 'workspaces: unknown field names' },
    { options = { workspaces = { workspaces = {} } }, message = 'option workspaces has fewer than 1 entries' },
    {
      options = { settings = { wristKeyboard = false } },
      message = 'plugin desktop settings: option wristKeyboard is a table, not a boolean',
    },
    {
      options = { settings = { wristKeyboard = {} }, patches = { { id = 'desktop/keyboard', config = {} } } },
      message = 'patch 1 and settings.wristKeyboard both configure desktop/keyboard',
    },
    {
      options = { settings = { persistence = {} }, patches = { { id = 'desktop/persistence', disabled = true } } },
      message = 'patch 1 and settings.persistence both configure desktop/persistence',
    },
    {
      options = { workspaces = WORKSPACES, settings = { workspace = {} } },
      message = 'both configure desktop/workspace',
    },
    {
      options = { workspaces = WORKSPACES, settings = { adoption = {} } },
      message = 'both configure desktop/adoption',
    },
    {
      options = { workspaces = WORKSPACES, patches = { { id = 'desktop/workspaces', config = {} } } },
      message = 'patch 1 and workspaces both configure desktop/workspaces',
    },
    {
      options = { workspaces = WORKSPACES, patches = { { id = 'desktop/workspace', disabled = true } } },
      message = 'both configure desktop/workspace',
    },
    {
      options = {
        workspaces = WORKSPACES,
        patches = { { insert = { id = 'desktop/workspaces', definition = workspaces } } },
      },
      message = 'patch 1 and workspaces both configure desktop/workspaces',
    },
    { options = { patches = { typo = true } }, message = 'the patch list is a list' },
  } do
    expect.raises(function()
      desktop.run(case.options :: any)
    end, case.message)
    expect.equal(lovr.load, load, 'invalid options bind no callbacks')
  end
  for _, id in ipairs { 'desktop/workspace', 'desktop/adoption' } do
    expect.raises(function()
      desktop.compose {
        entries = plugin.compose(desktop.entries(), { { id = id, config = {} } }),
        workspaces = WORKSPACES,
      }
    end, 'the configured entry ' .. id)
  end
  expect.raises(function()
    desktop.compose {
      entries = plugin.compose(
        desktop.entries(),
        { { insert = { id = 'desktop/workspaces', definition = workspaces } } }
      ),
      workspaces = WORKSPACES,
    }
  end, 'the configured entry desktop/workspaces')
end)

local function environment(config, fake, patches)
  local session = testing.boot(desktop.compose { workspaces = config, patches = patches }, { native = fake })
  local panels = session:observe(panelsContract.capability)
  local tags = session:observe(tagsContract.capability)
  return { session = session, panels = panels.service, tags = tags.service, owner = tags.context, native = fake }
end

local function open(env, window)
  env.native.events.windows[#env.native.events.windows + 1] = window
  env.native.emit('onWindowOpened', { window = window })
  return assert(env.panels:forSource(window))
end

local function selectWorkspace(env, name)
  local menu = env.session:observe(menuContract.capability).service
  expect.equal(menu:invoke('desktop/workspace/' .. name).kind, 'invoked', 'workspace action runs')
end

test('a renamed first workspace coordinates boot and later adoption without renaming explicit or saved tags', function()
  local fake = testing.native()
  local boot = fake.newWindow(310)
  fake.events.windows = { boot }
  fake.events.saved = 'return { version = 1, entries = { { kind = "monitor", key = "fixture-output", slot = 1, '
    .. 'pose = "1 0 0 0 0 1 0 0 0 0 1 0 0 1 -2 1", tags = { "main" } } } }'
  local monitor = fake.newMonitor 'fixture-output'
  fake.events.monitors[monitor.id] = monitor
  local config = { workspaces = { { name = 'work' }, { name = 'web' } } }
  local env = environment(config, fake, {
    {
      id = 'desktop/rules',
      config = { rules = { { match = { appId = 'mail' }, properties = { tags = { 'mail' } } } } },
    },
  })
  local work, web = assert(env.tags:find 'work'), assert(env.tags:find 'web')
  expect.truthy(work.selected and not web.selected, 'the first named workspace is selected')
  expect.truthy(work:has(env.panels:forSource(boot)), 'the boot window adopts the coordinated default')
  local saved = assert(env.panels:forSource(monitor))
  expect.truthy(assert(env.tags:find 'main'):has(saved), 'a persisted tag is not renamed')
  local explicit = open(env, fake.newWindow(311, 'mail'))
  expect.truthy(assert(env.tags:find 'mail'):has(explicit), 'an explicit rule tag is not renamed')
  expect.falsy(work:has(explicit), 'an explicit rule replaces the default')
  selectWorkspace(env, 'web')
  local later = open(env, fake.newWindow(312))
  expect.truthy(web:has(later) and not work:has(later), 'a later window follows the selected workspace')
  expect.falsy(explicit.hidden or saved.hidden, 'unlisted tags remain outside workspace visibility policy')
  env.session:close()
end)

test('workspace following observes adoption already present at boot', function()
  local fake = testing.native()
  local window = fake.newWindow(320, 'web-client')
  fake.events.windows = { window }
  local config = { workspaces = { { name = 'work' }, { name = 'web' } } }
  local env = environment(config, fake, {
    {
      id = 'desktop/rules',
      config = { rules = { { match = { appId = 'web-client' }, properties = { tags = { 'web' } } } } },
    },
  })
  local panel = assert(env.panels:forSource(window))
  expect.truthy(assert(env.tags:find 'work'):has(panel), 'the boot placement follows the selected workspace')
  expect.falsy(assert(env.tags:find 'web'):has(panel), 'the placement listener already runs during adoption')
  env.session:close()
end)

test('workspace following applies to saved boot windows and can preserve their membership', function()
  for _, follow in { true, false } do
    local fake = testing.native()
    local window = fake.newWindow(325, 'saved-window')
    fake.events.windows = { window }
    fake.events.saved = 'return { version = 1, entries = { { kind = "window", key = "saved-window", slot = 1, '
      .. 'pose = "1 0 0 0 0 1 0 0 0 0 1 0 0 1 -2 1", tags = { "web" } } } }'
    local env = environment({
      workspaces = { { name = 'work' }, { name = 'web' } },
      follow = follow,
    }, fake)
    local panel = assert(env.panels:forSource(window))
    expect.equal(assert(env.tags:find 'work'):has(panel), follow, 'following moves the saved window to work')
    expect.equal(
      assert(env.tags:find 'web'):has(panel),
      not follow,
      'disabled following preserves the saved membership'
    )
    expect.equal(panel.hidden, not follow, 'the saved window is visible only in the selected workspace')
    if not follow then
      selectWorkspace(env, 'web')
      expect.falsy(panel.hidden, 'selecting the saved workspace shows its window')
    end
    env.session:close()
  end
end)

test('two starts of one expanded composition keep workspace selection independent', function()
  local entries = desktop.compose { workspaces = WORKSPACES }
  local first = testing.boot(entries)
  selectWorkspace({ session = first }, 'side')
  expect.truthy(first:observe(tagsContract.capability).service:find('side').selected, 'the first runtime switches')
  first:close()
  local second = testing.boot(entries)
  local tags = second:observe(tagsContract.capability).service
  expect.truthy(tags:find('main').selected and not tags:find('side').selected, 'the second runtime starts fresh')
  second:close()
end)

test('disabling follow preserves an explicit boot workspace membership', function()
  local fake = testing.native()
  local window = fake.newWindow(330, 'web-client')
  fake.events.windows = { window }
  local env = environment(
    {
      workspaces = { { name = 'work' }, { name = 'web' } },
      follow = false,
    },
    fake,
    {
      {
        id = 'desktop/rules',
        config = { rules = { { match = { appId = 'web-client' }, properties = { tags = { 'web' } } } } },
      },
    }
  )
  local panel = assert(env.panels:forSource(window))
  expect.truthy(assert(env.tags:find 'web'):has(panel), 'the explicit tag remains')
  expect.falsy(assert(env.tags:find 'work'):has(panel), 'the default does not replace an explicit rule')
  expect.truthy(panel.hidden, 'the unselected configured workspace is hidden')
  selectWorkspace(env, 'web')
  expect.falsy(panel.hidden, 'the explicit workspace can be selected')
  env.session:close()
end)

return test

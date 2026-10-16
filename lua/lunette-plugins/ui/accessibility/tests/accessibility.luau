local testing = require '@testing'
local accessibility = require '@lunette-contracts/accessibility'
local format = require '../private/format'
local fixture = require '@testing/ui-host'
local expect = testing.expect
local test = testing.suite()

test('settings round-trip through the file, keeping fields this version does not know', function()
  local text = [[return {
  version = 1,
  settings = {
    textScale = 1.5,
    highContrast = true,
    futureSetting = { level = 3, names = { 'a', 'b' } },
  },
}]]
  local loaded = format.read(text)
  assert(loaded.kind == 'settings', 'the file loads')
  expect.equal(loaded.file.settings.textScale, 1.5)
  expect.equal(loaded.file.settings.reducedMotion, false, 'missing settings take their defaults')
  local again = format.read(format.render(loaded.file))
  assert(again.kind == 'settings')
  expect.equal(again.file.settings.highContrast, true)
  expect.equal(again.file.unknown.futureSetting.level, 3, 'an unknown field survives a write')
  expect.equal(again.file.unknown.futureSetting.names[2], 'b')
end)

test('invalid values are skipped and named, and newer or broken files are refused', function()
  local loaded = format.read 'return { version = 1, settings = { textScale = 9, haptics = "yes", sounds = false } }'
  assert(loaded.kind == 'settings')
  expect.equal(table.concat(loaded.skipped, ','), 'haptics,textScale')
  expect.equal(loaded.file.settings.textScale, 1, 'an out-of-range scale keeps the default')
  expect.equal(loaded.file.settings.sounds, false)
  local future = format.read 'return { version = 2, settings = {} }'
  expect.equal(future.kind, 'fromTheFuture')
  expect.equal(format.read('return (').kind, 'broken')
  expect.equal(format.read('error("no")').kind, 'broken')
  expect.equal(format.read('return os.exit()').kind, 'broken', 'the file runs in an empty environment')
end)

test('the provider saves changes, and the host applies text scale and high contrast', function()
  local state = fixture.boot {
    standard = true,
    plugins = { require('@lunette-plugins/ui/accessibility').definition },
  }
  local observed = assert(state.fixture.session):observe(accessibility.capability)
  local service = assert(observed.service)
  local before = state.service:theme().type.body.size
  service:update { textScale = 1.5, highContrast = true }
  expect.near(state.service:theme().type.body.size, before * 1.5, 1e-9, 'the host scales its type')
  local saved = state.fixture.native.events.files['accessibility.settings']
  assert(saved, 'the settings were saved')
  local loaded = format.read(saved)
  assert(loaded.kind == 'settings')
  expect.equal(loaded.file.settings.highContrast, true)
  expect.raises(function()
    service:update { textScale = 7 }
  end, 'not a valid textScale')
  state.fixture:close()
end)

test('the wrist menu action opens the settings panel, whose toggles change the settings', function()
  local menu = require '@lunette-contracts/menu'
  local state = fixture.boot {
    standard = true,
    plugins = {
      require('@lunette-plugins/menu/action-registry').definition,
      require('@lunette-plugins/ui/accessibility').definition,
      require('@lunette-plugins/ui/accessibility-settings').definition,
    },
  }
  local session = assert(state.fixture.session)
  local menus = assert(session:observe(menu.capability).service)
  local service = assert(session:observe(accessibility.capability).service)
  expect.equal(menus:invoke('desktop/accessibility').kind, 'invoked')
  state.fixture:step()
  state.fixture:step()
  local toggle = assert(state.service:find 'Accessibility:body/display/content/highContrast/row', 'the panel is open')
  state.fixture:click(fixture.nodeGeometry(toggle), 0.5, 0.5)
  expect.equal(service.settings:get().highContrast, true, 'the toggle changed the setting')
  expect.equal(menus:invoke('desktop/accessibility').kind, 'invoked')
  state.fixture:step()
  expect.equal(state.service:find 'Accessibility:body', nil, 'the action closes the open panel')
  state.fixture:close()
end)

return test

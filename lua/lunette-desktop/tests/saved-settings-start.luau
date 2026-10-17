-- A setting saved in an earlier session applies when the desktop starts. The desktop starts once per Lua state, so
-- this is apart from the test that saves.
local testing = require '@testing'
local expect = testing.expect
local adapter = require '@lunette-plugin/adapter'
local desktop = require '@lunette-desktop'
local theme = require '@lunette-contracts/theme'
local uiHost = require '@lunette-contracts/ui-host'
local versionedFile = require '@lunette-plugins/storage/versioned-file'
local test = testing.suite()

-- Starts the desktop with an observer that holds the theme and makes one grabbable world panel.
local function start(): (theme.Service, uiHost.Panel)
  local service: theme.Service? = nil
  local panel: uiHost.Panel? = nil
  local observer = adapter.define {
    name = 'saved-settings-observer',
    requires = { theme.capability, uiHost.capability },
    init = function(context: adapter.Context)
      service = context:require(theme.capability)
      panel = context:require(uiHost.capability):newPanel(context, {
        name = 'saved-settings-panel',
        width = 0.3,
        height = 0.2,
        pose = lovr.math.newMat4():translate(0, 1.4, -0.8),
      })
    end,
  }
  desktop.run {
    settings = { theme = { mode = 'dark' } },
    patches = { { insert = { id = 'saved-settings-observer', definition = observer } } },
  }
  lovr.load()
  return assert(service, 'the observer sees the theme'), assert(panel, 'the observer makes its panel')
end

test('a saved theme mode and panel placement apply at the next start', function()
  local native = testing.native()
  native.events.files['settings.saved'] = versionedFile.render({
    entries = {
      theme = { mode = 'light' },
      ['ui-host'] = {
        placed = { ['saved-settings-panel'] = { position = vector.create(0.5, 1.2, -1), rotation = { 0, 0, 1, 0 } } },
      },
    },
  }, 1)
  local service, panel = start()
  expect.equal(service:current().mode, 'light', 'the saved mode wins over the configured one')
  local position = vector.pack(panel:pose():getPosition())
  expect.near(position.x, 0.5, 1e-6, 'the panel opens where it was left, not at its owner pose')
  expect.near(position.z, -1, 1e-6)
  local shutdown = testing.host.shutdown()
  expect.equal(#shutdown, 0, table.concat(shutdown, '\n'))
end)

return test

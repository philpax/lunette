-- A setting changed in a session is saved by the desktop and applies at the next start.
local testing = require '@testing'
local expect = testing.expect
local adapter = require '@lunette-plugin/adapter'
local desktop = require '@lunette-desktop'
local theme = require '@lunette-contracts/theme'
local uiHost = require '@lunette-contracts/ui-host'
local versionedFile = require '@lunette-plugins/storage/versioned-file'
local vrUi = require '@testing/vr-ui'
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

test('a theme mode and where a grab leaves a panel are saved in the save directory', function()
  local native = testing.native()
  local first, panel = start()
  expect.equal(first:current().mode, 'dark', 'the configured mode applies')
  first:setMode 'light'
  local text = assert(native.events.files['settings.saved'], 'the desktop saves the change')
  local loaded = versionedFile.parse(text, 'settings.saved', 1)
  assert(loaded.kind == 'data', 'the file parses')
  expect.equal(loaded.data.entries.theme.mode, 'light', 'the file holds the saved mode')

  -- The grip carries the panel half a metre to the right, and the panel rests there.
  local controls = vrUi.attach(native)
  local width, height = panel:size()
  local geometry = {
    pose = panel:pose(),
    width = width,
    height = height,
    logicalWidth = width,
    logicalHeight = height,
    visible = true,
  }
  controls:aim(geometry, width / 2, height / 2, 'right')
  controls:step()
  controls:button('right', 'grip', true)
  controls:step()
  for step = 1, 5 do
    controls:aim(geometry, width / 2 + 0.1 * step, height / 2, 'right')
    controls:step()
  end
  controls:button('right', 'grip', false)
  controls:step(1)
  local moved = vector.pack(panel:pose():getPosition())
  expect.near(moved.x, 0.5, 0.02, 'the grip carried the panel')
  loaded = versionedFile.parse(assert(native.events.files['settings.saved']), 'settings.saved', 1)
  assert(loaded.kind == 'data', 'the file parses')
  local placement = loaded.data.entries['ui-host'].placed['saved-settings-panel']
  expect.near(placement.position.x, moved.x, 1e-6, 'the file holds where the panel rests')
  local shutdown = testing.host.shutdown()
  expect.equal(#shutdown, 0, table.concat(shutdown, '\n'))
end)

return test

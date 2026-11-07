-- Placement memory returns a toolkit panel to where it was dropped in an earlier session, and its saved placement wins
-- over one the UI host saved before placement memory existed. The desktop starts once per Lua state, so this is apart
-- from the test that saves.
local testing = require '@testing'
local expect = testing.expect
local adapter = require '@lunette-plugin/adapter'
local desktop = require '@lunette-desktop'
local uiHost = require '@lunette-contracts/ui-host'
local versionedFile = require '@lunette-plugins/storage/versioned-file'
local test = testing.suite()

test('a panel opens where placement memory saved it, zoomed to its saved width', function()
  local native = testing.native()
  native.events.files['settings.saved'] = versionedFile.render({
    entries = {
      ['ui-host'] = {
        placed = { ['remembered-panel'] = { position = vector.create(-0.5, 1.1, -1.2), rotation = { 0, 0, 1, 0 } } },
      },
      ['desktop/placement-memory'] = {
        placed = {
          ['remembered-panel'] = { position = vector.create(0.5, 1.2, -1), rotation = { 0, 0, 1, 0 }, width = 0.6 },
        },
      },
    },
  }, 1)
  local panel: uiHost.Panel? = nil
  local observer = adapter.define {
    name = 'placement-memory-observer',
    requires = { uiHost.capability },
    init = function(context: adapter.Context)
      panel = context:require(uiHost.capability):newPanel(context, {
        name = 'remembered-panel',
        width = 0.3,
        height = 0.2,
        pose = lovr.math.newMat4():translate(0, 1.4, -0.8),
      })
    end,
  }
  desktop.run { patches = { { insert = { id = 'placement-memory-observer', definition = observer } } } }
  lovr.load()
  lovr.update(0.016)
  local opened = assert(panel, 'the observer makes its panel')
  local position = vector.pack(opened:pose():getPosition())
  expect.near(position.x, 0.5, 1e-6, 'the panel opens where placement memory saved it')
  expect.near(position.z, -1, 1e-6)
  local width = opened:size()
  expect.near(width, 0.3, 1e-6, 'layout keeps its width')
  local shutdown = testing.host.shutdown()
  expect.equal(#shutdown, 0, table.concat(shutdown, '\n'))
end)

return test

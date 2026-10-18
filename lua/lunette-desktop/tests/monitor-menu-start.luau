-- A monitor whose mirror was closed in an earlier session starts unmirrored, with its menu action off. The desktop
-- starts once per Lua state, so this is apart from the test that saves.
local testing = require '@testing'
local expect = testing.expect
local adapter = require '@lunette-plugin/adapter'
local desktop = require '@lunette-desktop'
local menu = require '@lunette-contracts/menu'
local panelsContract = require '@lunette-contracts/panels'
local versionedFile = require '@lunette-plugins/storage/versioned-file'
local test = testing.suite()

test('a hidden monitor starts unmirrored, and the others mirror as usual', function()
  local native = testing.native()
  native.events.files['settings.saved'] =
    versionedFile.render({ entries = { ['desktop/monitors'] = { hidden = { 'monitor-a' } } } }, 1)
  local first, second = native.newMonitor 'monitor-a', native.newMonitor 'monitor-b'
  native.events.monitors = { first, second }
  local menus: menu.Service? = nil
  local panels: panelsContract.Service? = nil
  desktop.run {
    patches = {
      {
        insert = {
          id = 'monitor-menu-observer',
          definition = adapter.define {
            name = 'monitor-menu-observer',
            requires = { menu.capability, panelsContract.capability },
            init = function(context: adapter.Context)
              menus = context:require(menu.capability)
              panels = context:require(panelsContract.capability)
            end,
          },
        },
      },
    },
  }
  lovr.load()
  lovr.update(0.016)
  local mirrors = assert(panels)
  expect.equal(mirrors:forSource(first), nil, 'the hidden monitor is not mirrored')
  expect.truthy(mirrors:forSource(second), 'the other monitor is')
  local states: { [string]: boolean } = {}
  for _, descriptor in assert(menus):list() do
    states[descriptor.id] = descriptor.selected
  end
  expect.equal(states['desktop/monitors/monitor-a'], false, 'the hidden monitor has an action that is off')
  expect.equal(states['desktop/monitors/monitor-b'], true)
  local shutdown = testing.host.shutdown()
  expect.equal(#shutdown, 0, table.concat(shutdown, '\n'))
end)

return test

-- A panel left open in an earlier session opens at the next start. The desktop starts once per Lua state, so this is
-- apart from the test that saves.
local testing = require '@testing'
local expect = testing.expect
local adapter = require '@lunette-plugin/adapter'
local desktop = require '@lunette-desktop'
local menu = require '@lunette-contracts/menu'
local versionedFile = require '@lunette-plugins/storage/versioned-file'
local test = testing.suite()

test('panels saved as open start open, with their menu actions selected', function()
  local native = testing.native()
  native.events.files['settings.saved'] = versionedFile.render({
    entries = {
      ['desktop/accessibility'] = { visible = true },
      ['desktop/manager'] = { visible = true },
      ['desktop/backdrop'] = { controlsVisible = true },
    },
  }, 1)
  local menus: menu.Service? = nil
  desktop.run {
    patches = {
      {
        insert = {
          id = 'panel-visibility-observer',
          definition = adapter.define {
            name = 'panel-visibility-observer',
            requires = { menu.capability },
            init = function(context: adapter.Context)
              menus = context:require(menu.capability)
            end,
          },
        },
      },
    },
  }
  lovr.load()
  lovr.update(0.016)
  local selected: { [string]: boolean } = {}
  for _, descriptor in assert(menus):list() do
    selected[descriptor.id] = descriptor.selected
  end
  for _, id in { 'desktop/accessibility', 'desktop/manager/open', 'desktop/backdrop/open' } do
    expect.equal(selected[id], true, `{id} starts open`)
  end
  local shutdown = testing.host.shutdown()
  expect.equal(#shutdown, 0, table.concat(shutdown, '\n'))
end)

return test

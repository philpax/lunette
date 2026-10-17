-- Opening and closing a panel from the wrist menu saves whether it is open. The desktop starts once per Lua state, so
-- the start that applies the saved state is in its own file.
local testing = require '@testing'
local expect = testing.expect
local adapter = require '@lunette-plugin/adapter'
local desktop = require '@lunette-desktop'
local menu = require '@lunette-contracts/menu'
local versionedFile = require '@lunette-plugins/storage/versioned-file'
local test = testing.suite()

local ACTIONS = {
  { action = 'desktop/accessibility', entry = 'desktop/accessibility', field = 'visible' },
  { action = 'desktop/manager/open', entry = 'desktop/manager', field = 'visible' },
  { action = 'desktop/backdrop/open', entry = 'desktop/backdrop', field = 'controlsVisible' },
}

local function saved(native: testing.Native): { [string]: any }
  local loaded = versionedFile.parse(assert(native.events.files['settings.saved']), 'settings.saved', 1)
  assert(loaded.kind == 'data', 'the file parses')
  return loaded.data.entries
end

test('each menu panel saves that it is open, and that it is closed again', function()
  local native = testing.native()
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
  local service = assert(menus, 'the observer sees the menu')
  for _, case in ACTIONS do
    expect.equal(service:invoke(case.action).kind, 'invoked', case.action)
    lovr.update(0.016)
    expect.equal(saved(native)[case.entry][case.field], true, `{case.entry} saves that it is open`)
  end
  for _, case in ACTIONS do
    expect.equal(service:invoke(case.action).kind, 'invoked', case.action)
    lovr.update(0.016)
    local entry = saved(native)[case.entry]
    expect.equal(entry and entry[case.field], nil, `{case.entry} saves that it is closed, as configured`)
  end
  local shutdown = testing.host.shutdown()
  expect.equal(#shutdown, 0, table.concat(shutdown, '\n'))
end)

return test

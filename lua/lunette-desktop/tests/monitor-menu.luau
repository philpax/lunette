-- Each monitor has a wrist-menu action that mirrors it or closes its mirror, and a closed mirror is saved as hidden.
-- The desktop starts once per Lua state, so the start from a saved file is in its own test file.
local testing = require '@testing'
local expect = testing.expect
local adapter = require '@lunette-plugin/adapter'
local desktop = require '@lunette-desktop'
local menu = require '@lunette-contracts/menu'
local panelsContract = require '@lunette-contracts/panels'
local versionedFile = require '@lunette-plugins/storage/versioned-file'
local test = testing.suite()

local function hidden(native: testing.Native): { string }
  local text = native.events.files['settings.saved']
  if not text then
    return {}
  end
  local loaded = versionedFile.parse(text, 'settings.saved', 1)
  assert(loaded.kind == 'data', 'the file parses')
  local entry = loaded.data.entries['desktop/monitors']
  return entry and entry.hidden or {}
end

local function selected(menus: menu.Service, id: string): boolean?
  for _, descriptor in menus:list() do
    if descriptor.id == id then
      return descriptor.selected
    end
  end
  return nil
end

test(
  'turning a mirror off from the menu or closing it from its titlebar keeps it closed, and the menu reopens it',
  function()
    local native = testing.native()
    local first, second = native.newMonitor 'monitor-a', native.newMonitor 'monitor-b'
    native.events.monitors = { first, second }
    local menus: menu.Service? = nil
    local panels: panelsContract.Service? = nil
    local owner: adapter.Context? = nil
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
                owner = context
              end,
            },
          },
        },
      },
    }
    lovr.load()
    lovr.update(0.016)
    local service, mirrors = assert(menus), assert(panels)
    expect.truthy(mirrors:forSource(first) and mirrors:forSource(second), 'both monitors are mirrored')
    expect.equal(selected(service, 'desktop/monitors/monitor-a'), true, 'a mirrored monitor has a selected action')

    expect.equal(service:invoke('desktop/monitors/monitor-a').kind, 'invoked')
    lovr.update(0.016)
    expect.equal(mirrors:forSource(first), nil, 'the action closes the mirror')
    expect.equal(selected(service, 'desktop/monitors/monitor-a'), false)
    expect.equal(table.concat(hidden(native), ','), 'monitor-a', 'the closed mirror is saved as hidden')

    assert(mirrors:forSource(second)):close(assert(owner))
    lovr.update(0.016)
    expect.equal(selected(service, 'desktop/monitors/monitor-b'), false, 'a titlebar close deselects the action')
    expect.equal(table.concat(hidden(native), ','), 'monitor-a,monitor-b', 'and saves the mirror as hidden')

    expect.equal(service:invoke('desktop/monitors/monitor-a').kind, 'invoked')
    lovr.update(0.016)
    expect.truthy(mirrors:forSource(first), 'the action mirrors the monitor again')
    expect.equal(selected(service, 'desktop/monitors/monitor-a'), true)
    expect.equal(table.concat(hidden(native), ','), 'monitor-b', 'and it is no longer hidden')

    first.dead = true
    native.events.monitors = { second }
    lovr.update(0.016)
    lovr.update(0.016)
    expect.equal(selected(service, 'desktop/monitors/monitor-a'), nil, 'a monitor that is gone loses its action')
    expect.equal(table.concat(hidden(native), ','), 'monitor-b', 'unplugging does not hide a monitor')
    local shutdown = testing.host.shutdown()
    expect.equal(#shutdown, 0, table.concat(shutdown, '\n'))
  end
)

return test

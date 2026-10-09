local testing = require '@testing'
local expect = testing.expect
local desktop = require '@lunette-desktop'
local menuContract = require '@lunette-contracts/menu'
local panelsContract = require '@lunette-contracts/panels'

local test = testing.suite()

local function exampleEntries()
  return desktop.compose {
    patches = {
      { insert = { id = 'hide-windows', definition = require 'hide-windows' } },
      { insert = { id = 'save-menu', definition = require 'save-menu' } },
    },
  }
end

local function action(actions, id)
  for _, row in actions.service:list() do
    if row.id == id then
      return row
    end
  end
  error('missing example action ' .. id)
end

test('the desktop example runs, and its menu action hides and shows windows without keyboard input', function()
  local native = testing.native()
  local events = native.events
  testing.host.useConfiguration 'examples/desktop'
  require 'main'
  lovr.load()
  lovr.update(0.016)
  expect.equal(lovr.draw(events.pass), false, 'draw does not veto')
  expect.equal(lovr.quit(), false, 'quit does not veto')

  local session = testing.boot(exampleEntries(), { native = native })
  local actions = session:observe(menuContract.capability)
  local panels = session:observe(panelsContract.capability)
  events.windows = { native.newWindow(1) }
  native.emit('onWindowOpened', { window = events.windows[1] })
  local panel = assert(panels.service:forSource(events.windows[1]))
  local function frame()
    events.draw, events.textures = {}, 0
    session:update()
    expect.equal(session:draw(), false, 'draw does not veto')
  end
  local id = 'example/hide-windows'
  frame()
  expect.equal(events.textures, 1, 'the window draws')
  expect.equal(action(actions, id).selected, false, 'the initial toggle state')
  expect.equal(actions.service:invoke(id).kind, 'invoked', 'the hide action')
  frame()
  expect.equal(events.textures, 0, 'the action hides the window')
  expect.equal(action(actions, id).selected, true, 'the hidden toggle state')
  expect.equal(actions.service:invoke(id).kind, 'invoked', 'the show action')
  frame()
  expect.equal(events.textures, 1, 'the action shows the window again')
  expect.equal(action(actions, id).selected, false, 'the shown toggle state')
  session:close()
end)

test('the save and restore menu actions use the arrangement service without forcing refused writes', function()
  testing.host.useConfiguration 'examples/desktop'
  local native = testing.native()
  local session = testing.boot(exampleEntries(), { native = native })
  local actions = session:observe(menuContract.capability)
  local panels = session:observe(panelsContract.capability)
  local window = native.newWindow(1)
  native.events.windows = { window }
  native.emit('onWindowOpened', { window = window })
  local panel = assert(panels.service:forSource(window))
  panel:setPose(lovr.math.newMat4():translate(3, 2, -4))
  expect.equal(actions.service:invoke('example/save-arrangement').kind, 'invoked', 'the save action')
  expect.equal(native.events.writes, 1, 'the arrangement saves once')
  panel:setPose(lovr.math.newMat4():translate(8, 7, -9))
  expect.equal(actions.service:invoke('example/restore-arrangement').kind, 'invoked', 'the restore action')
  expect.near((panel.pose:getPosition()), 3, 1e-5, 'restore applies the saved pose')
  session:close()

  native = testing.native()
  native.events.saved = 'invalid arrangement'
  session = testing.boot(exampleEntries(), { native = native })
  actions = session:observe(menuContract.capability)
  expect.equal(actions.service:invoke('example/save-arrangement').kind, 'invoked', 'a refused save completes')
  expect.equal(native.events.writes, 0, 'the example does not force an overwrite')
  expect.equal(native.events.saved, 'invalid arrangement', 'the refused file remains unchanged')
  local warning = native.events.logs[#native.events.logs]
  expect.truthy(warning[1]:find('the arrangement was not saved:', 1, true), 'the refusal warning')
  session:close()
end)

return test

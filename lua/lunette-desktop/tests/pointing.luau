-- Interaction and laser outages stop pointing without removing panels. An interaction outage during a drag saves the last pose.
local testing = require '@testing'
local expect = testing.expect
local desktop = require '@lunette-desktop'
local persist = require '@lunette-plugins/arrangement/format'
local panelsContract = require '@lunette-contracts/panels'
local vocabulary = require '@lunette-contracts/vocabulary'
local plugin = require '@lunette-plugin'
local surfaces = require '@lunette-contracts/surfaces'
local quad = require '@lunette-contracts/quad'
local vrUi = require '@testing/vr-ui'

local test = testing.suite()

local function liveSeats(events)
  local count = 0
  for _, seat in ipairs(events.seats) do
    if not seat.dead then
      count += 1
    end
  end
  return count
end

local function start()
  local session = testing.boot(desktop.entries())
  local native = session.native
  session.hands = vrUi.hands(native)
  local panels = session:observe(panelsContract.capability)
  local window = native.newWindow(1)
  native.events.windows = { window }
  native.emit('onWindowOpened', { window = window })
  return session, window, assert(panels.service:forSource(window)), panels
end

local function frame(session)
  session.native.events.textures = 0
  session:update()
  expect.equal(session:draw(), false, 'draw does not veto')
end

test('an interaction or laser outage unloads pointing and keeps panels placed and drawn', function()
  local session, window, panel, panels = start()
  local events, instances = session.native.events, session.instances
  frame(session)
  expect.equal(liveSeats(events), 2, 'a seat for each laser')
  for _, name in ipairs { 'interaction', 'laser' } do
    instances[name]:disable()
    expect.truthy(instances['desktop/pointing']:state() ~= 'active', name .. ' outage unloads pointing')
    expect.equal(instances['desktop/render']:state(), 'active', name .. ' outage keeps rendering')
    expect.equal(instances['desktop/arrange']:state(), 'active', name .. ' outage keeps arranging')
    expect.truthy(panels.service:forSource(window) == panel and not panel.dead, name .. ' outage keeps the panel')
    expect.equal(liveSeats(events), 0, name .. ' outage releases the laser seats')
    frame(session)
    expect.equal(events.textures, 1, name .. ' outage keeps the panel drawing')
    instances[name]:enable()
    expect.equal(instances['desktop/pointing']:state(), 'active', name .. ' recovery restores pointing')
    expect.equal(liveSeats(events), 2, name .. ' recovery makes the seats again')
  end
  session:close()
end)

test('an interaction outage mid-drag saves the drop, and the saved pose agrees with the stored one', function()
  local session, window, panel = start()
  local events = session.native.events
  frame(session)
  session.hands:button('right', 'grip', true)
  frame(session)
  session.hands:pose('right', lovr.math.newMat4():translate(0.5, 1.5, 0))
  frame(session)
  expect.near((panel.pose:getPosition()), 0.5, 1e-5, 'the drag moved the panel')

  local writes = events.writes
  session.instances.interaction:disable()
  session.hands:button('right', 'grip', false)
  session.hands:pose('right', lovr.math.newMat4():translate(0, 1.5, 0))
  local stored = window.properties[vocabulary.POSE_PROPERTY]
  expect.truthy(stored, 'the abandoned grab stored the pose')
  expect.equal(events.writes, writes + 1, 'the abandoned grab saved the arrangement')
  local loaded = persist.read(events.saved)
  expect.equal(loaded.kind, 'arrangement', 'the saved file')
  local entry = loaded.file.entries[1]
  expect.equal(entry and entry.pose, stored, 'the saved pose and the stored property agree')
  session.instances.interaction:enable()
  frame(session)
  expect.equal(events.textures, 1, 'the panel draws after recovery')
  session:close()
end)

test('the trigger and thumbstick reach a native sink as a primary button and scroll', function()
  local fixture = vrUi.boot {
    'frame',
    'theme',
    'surfaces',
    'drops',
    'focus',
    'interaction',
    {
      id = 'laser',
      definition = require('@lunette-plugins/laser').definition,
      config = { aim = { enabled = false }, triggerLock = { enabled = false } },
    },
    'keyboard',
    'desktop/pointing',
  }
  local window = fixture.native.newWindow(17)
  local pose = lovr.math.newMat4():translate(0, 1.5, -2)
  local presses = 0
  fixture.session:use(plugin.define {
    name = 'testing/native-sink',
    requires = { surfaces = surfaces.capability },
    init = function(context)
      local target =
        { dead = false, grabbable = false, pose = pose, width = 2, height = 1, pixelWidth = 200, pixelHeight = 100 }
      function target:raycast(origin, direction)
        return quad.hit(self, origin, direction)
      end
      function target:project(origin, direction)
        return quad.project(self, origin, direction)
      end
      function target:sink()
        return window.sink
      end
      function target:onPointer(event)
        if event.kind == 'press' then
          presses += 1
        end
      end
      context:require(surfaces.capability):offer(context, {
        name = 'native-sink',
        list = function()
          return { target }
        end,
      })
    end,
  })
  local description = {
    visible = true,
    pose = { pose:unpack(true) },
    width = 2,
    height = 1,
    logicalWidth = 200,
    logicalHeight = 100,
  }
  fixture:aim(description, 80, 50, 'right')
  fixture:step()
  fixture:button('right', 'trigger', true)
  fixture:step()
  fixture:axis('right', 0.5, 0.75)
  fixture:step()
  fixture:button('right', 'trigger', false)
  fixture:step()
  local buttons = fixture:nativeCalls 'button'
  expect.equal(#buttons, 2, 'one native press and release')
  expect.equal(buttons[1][2], 'left', 'the trigger maps to the primary pointer button')
  expect.equal(buttons[1][3], true, 'the press')
  expect.equal(buttons[2][3], false, 'the release')
  expect.truthy(#fixture:nativeCalls 'pointer' > 0, 'native pointer motion')
  expect.truthy(#fixture:nativeCalls 'scroll' > 0, 'native scaled scroll')
  expect.equal(presses, 0, 'native delivery does not also call the Lua press callback')
end)

return test

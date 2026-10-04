-- Interaction and laser outages stop pointing without removing panels. An interaction outage during a drag saves the last pose.
local testing = require '@testing'
local expect = testing.expect
local desktop = require '@lunette-desktop'
local persist = require '@lunette-plugins/arrangement'
local panelsContract = require '@lunette-contracts/panels'
local vocabulary = require '@lunette-contracts/vocabulary'

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
  events.grip = true
  frame(session)
  events.handX = 0.5
  frame(session)
  expect.near((panel.pose:getPosition()), 0.5, 1e-5, 'the drag moved the panel')

  local writes = events.writes
  session.instances.interaction:disable()
  events.grip = false
  events.handX = nil
  local stored = window.properties[vocabulary.POSE_PROPERTY]
  expect.truthy(stored, 'the abandoned grab stored the pose')
  expect.equal(events.writes, writes + 1, 'the abandoned grab saved the arrangement')
  local loaded = persist.read(events.saved)
  expect.equal(loaded.kind, 'arrangement', 'the saved file')
  local entry = persist.entries(loaded.file)[1]
  expect.equal(entry and entry.pose, stored, 'the saved pose and the stored property agree')
  session.instances.interaction:enable()
  frame(session)
  expect.equal(events.textures, 1, 'the panel draws after recovery')
  session:close()
end)

return test

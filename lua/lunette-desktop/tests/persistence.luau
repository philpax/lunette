-- Saved poses override rule poses, native pose properties take precedence, and unreadable files remain unchanged across outages and quit.
local testing = require '@testing'
local expect = testing.expect
local persist = require '@lunette-plugins/arrangement'
local panelsContract = require '@lunette-contracts/panels'
local vocabulary = require '@lunette-contracts/vocabulary'

local test = testing.suite()

local PROVIDERS =
  { 'frame', 'theme', 'panels', 'drops', 'tags', 'rules', 'placement', 'adoption', 'layouts', 'layout/arc' }

-- Each consumer group uses fresh factories and reads the arrangement file independently.
local function placementConsumers(session)
  local instances = {
    session:use(require '@lunette-plugins/desktop/workspaces'),
    session:use(require '@lunette-plugins/desktop/rules'),
    session:use(persist.factory()),
    session:use(require '@lunette-plugins/desktop/arrange'()),
    session:use(require '@lunette-plugins/desktop/adoption'),
  }
  return function()
    for index = #instances, 1, -1 do
      instances[index]:dispose()
    end
  end
end

local function expectAt(panel, x, y, z, context)
  local px, py, pz = panel.pose:getPosition()
  expect.near(px, x, 1e-5, context .. ', x')
  expect.near(py, y, 1e-5, context .. ', y')
  expect.near(pz, z, 1e-5, context .. ', z')
end

test('a saved pose overrides a configured rule and yields to the native pose property', function()
  local session = testing.boot(PROVIDERS)
  local native, events = session.native, session.native.events
  local panels = session:observe(panelsContract.capability)
  local dispose = placementConsumers(session)
  -- The shipped rules give firefox a pose of their own.
  local window = native.newWindow(20, 'firefox')
  events.windows = { window }
  native.emit('onWindowOpened', { window = window })
  local created = assert(panels.service:forSource(window))
  created:setPose(lovr.math.newMat4():translate(4, 3, -6))
  session:drop(created)
  expect.equal(events.writes, 1, 'the drop saves the arrangement')
  dispose()

  window:setProperty(vocabulary.POSE_PROPERTY, nil)
  dispose = placementConsumers(session)
  expectAt(assert(panels.service:forSource(window)), 4, 3, -6, 'the saved pose overrides the configured rule')
  dispose()

  window:setProperty(vocabulary.POSE_PROPERTY, vocabulary.encodePose(lovr.math.newMat4():translate(8, 7, -9)))
  dispose = placementConsumers(session)
  expectAt(assert(panels.service:forSource(window)), 8, 7, -9, 'the native property overrides the saved pose')
  dispose()
  session:close()
end)

test('an unreadable file is not overwritten through outages, drops, or quit', function()
  local fake = testing.native()
  fake.events.saved = 'invalid arrangement'
  local session = testing.boot(PROVIDERS, { native = fake })
  local events = fake.events
  local panels = session:observe(panelsContract.capability)
  placementConsumers(session)
  local window = fake.newWindow(20, 'firefox')
  events.windows = { window }
  fake.emit('onWindowOpened', { window = window })
  local reads, writes = events.reads, events.writes
  for round = 1, 3 do
    local context = 'round ' .. round
    session.instances.tags:disable()
    expect.equal(events.writes, writes, context .. ': unloading does not overwrite the unreadable file')
    session.instances.tags:enable()
    session:drop(assert(panels.service:forSource(window)))
    expect.equal(events.writes, writes, context .. ': a drop does not overwrite it')
    expect.equal(events.saved, 'invalid arrangement', context .. ': the file')
    expect.equal(events.reads, reads, context .. ': the refusal survives reactivation without reading again')
  end
  session.instances.tags:disable()
  expect.equal(session:quit(), false, 'quit does not veto')
  expect.equal(events.writes, writes, 'inactive persistence has no save at quit')
  session:close()
end)

return test

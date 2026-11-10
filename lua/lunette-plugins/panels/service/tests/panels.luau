local testing = require '@testing'
local expect = testing.expect
local contract = require '@lunette-contracts/panels'

local test = testing.suite()

type Config = testing.ConfiguredInput<typeof(require('../').define)>
type Texture = { read getDimensions: () -> (number, number) }
type Environment = {
  native: testing.Native,
  session: testing.Session?,
  panels: contract.Service?,
  owner: testing.Context?,
  other: testing.Context?,
}

local function start(config: Config?): Environment
  local env: Environment = { native = testing.native() }
  env.session = testing.start {
    'theme',
    { id = 'panels', definition = require('../').definition, config = config },
  }
  local first = env.session:observe(contract.capability)
  env.panels, env.owner = first.service, first.context
  env.other = env.session:observe(contract.capability).context
  return env
end

test('a panel takes its size from its source, is found by it, and only its creator destroys it', function()
  local env = start()
  local source = env.native.newWindow(17)
  source.width, source.height = 800, 600
  local panel = env.panels:fromWindow(env.owner, source, { height = 1 })
  expect.equal(panel.kind, 'window', 'the kind')
  expect.near(panel.width, 4 / 3, 1e-9, 'the width')
  expect.equal(env.panels:forSource { id = 17 }, panel, 'the panel found by window id')
  expect.equal(env.panels:inspect().registrations[1].owner, env.owner, 'the inspected owner')
  expect.raises(function()
    panel:destroy(env.other)
  end, nil, 'a stranger destroying the panel')
  expect.truthy(panel:destroy(env.owner), 'the creator destroys it')
  expect.equal(#env.panels:all(), 0, 'the panels')
  env.session:close()
end)

test('a monitor panel follows its oriented geometry, and is removed once its source dies', function()
  local env = start()
  local source = env.native.newMonitor 'portrait'
  source.logicalWidth, source.logicalHeight = 1080, 1920
  local panel = env.panels:fromMonitor(env.owner, source, { width = 1 })
  expect.near(panel.height, 1920 / 1080, 1e-9, 'the portrait aspect')
  source.logicalWidth, source.logicalHeight = 1920, 1080
  env.panels:update()
  expect.near(panel.height, 1080 / 1920, 1e-9, 'rotation refreshes the aspect')
  source.dead = true
  env.panels:update()
  expect.truthy(panel.dead, 'the panel after its source died')
  expect.equal(#env.panels:all(), 0, 'the panels')
  env.session:close()
end)

test('listeners hear arrivals and removals, and a raising listener is reported while the others run', function()
  local env = start()
  local added: { contract.Panel } = {}
  local removed: { contract.Panel } = {}
  local everything: { contract.Panel } = {}
  env.panels:onAdded(env.owner, {
    run = function(created: contract.Panel)
      added[#added + 1] = created
    end,
  })
  env.panels:onAdded(env.owner, {
    run = function(): never
      error 'arrival listener failed'
    end,
  })
  local first = env.panels:fromWindow(env.owner, env.native.newWindow(1), { height = 1 })
  local second = env.panels:fromWindow(env.owner, env.native.newWindow(2), { height = 1 })
  expect.equal(added[1], first, 'the first arrival')
  expect.equal(#added, 2, 'the arrivals heard')
  env.panels:onRemoved(env.owner, {
    panel = first,
    run = function(target: contract.Panel)
      removed[#removed + 1] = target
    end,
  })
  env.panels:onRemoved(env.owner, {
    run = function(target: contract.Panel)
      everything[#everything + 1] = target
    end,
  })
  second:destroy(env.owner)
  expect.equal(#removed, 0, 'a listener for one panel does not hear another')
  first:destroy(env.owner)
  expect.equal(removed[1], first, 'the removed panel')
  expect.equal(#everything, 2, 'a listener for every panel')
  expect.equal(#env.native.events.reported, 2, 'each raising arrival is reported')
  env.session:close()
end)

test('the most recent live override decides whether a panel is hidden', function()
  local env = start { rendering = 'layer' }
  local source = env.native.newWindow(1)
  source.getTexture = function(): Texture
    return {
      getDimensions = function(): (number, number)
        return source.width, source.height
      end,
    }
  end
  local panel = env.panels:fromWindow(env.owner, source, { height = 1 })
  local claim = panel.claim
  local hiding = panel:setHidden(env.owner, true)
  expect.truthy(panel.hidden, 'the hidden panel')
  expect.truthy(claim.dead, 'hiding gives up the layer claim')
  expect.equal(panel:raycast(vector.pack(0, 0, 0), vector.pack(0, 0, -1)), nil, 'a hidden panel is not picked')
  local showing = panel:setHidden(env.other, false)
  expect.falsy(panel.hidden, 'the newer override shows the panel')
  hiding:dispose()
  showing:dispose()
  expect.falsy(panel.hidden, 'with no override the panel is shown')
  env.panels:update()
  expect.truthy(panel.claim and not panel.claim.dead, 'a shown panel claims again')
  env.session:close()
end)

test('input locks are panel state and keep content pickable while denying its sink', function()
  local env = start()
  local source = env.native.newWindow(21)
  local panel = env.panels:fromWindow(env.owner, source, { pose = lovr.math.newMat4():translate(0, 0, -2) })
  local changes = 0
  env.panels:onLockChanged(env.owner, {
    run = function(changed: contract.Panel)
      expect.equal(changed, panel, 'the changed panel')
      changes += 1
    end,
  })
  expect.falsy(panel.locked, 'unlocked by default')
  expect.truthy(panel:setLocked(env.other, true), 'another live owner can lock')
  expect.truthy(panel.locked, 'the panel owns the state')
  expect.equal(panel:sink(), nil, 'content exposes no input sink')
  expect.truthy(env.panels:isInputLocked(source.sink), 'raw sink routes are denied')
  local _, _, distance = panel:raycast(vector.pack(0, 0, 0), vector.pack(0, 0, -1))
  expect.truthy(distance, 'locked content still occludes')
  expect.falsy(panel:setLocked(env.owner, true), 'idempotent toggles do not notify')
  expect.equal(changes, 1, 'one transition')
  expect.truthy(panel:setLocked(env.owner, false), 'unlock succeeds')
  expect.equal(panel:sink(), source.sink, 'fresh input can use the sink')
  env.session:close()
end)

test('duplicate panels share sink lock eligibility and validate lock values', function()
  local env = start()
  local source = env.native.newWindow(22)
  local first = env.panels:fromWindow(env.owner, source)
  local second = env.panels:fromWindow(env.owner, source, { locked = true })
  expect.truthy(env.panels:isInputLocked(first:sink()), 'one locked duplicate denies the shared sink')
  second:setLocked(env.owner, false)
  expect.falsy(env.panels:isInputLocked(source.sink), 'all duplicates must be unlocked')
  expect.raises(function()
    first:setLocked(env.owner, 'locked')
  end, nil, 'invalid transition value')
  expect.raises(function()
    env.panels:fromWindow(env.owner, source, { locked = 'locked' })
  end, nil, 'invalid initial lock')
  env.session:close()
end)

test('a panel changes its curve at runtime and maps a ray to planar source pixels', function()
  local env = start { style = { windowRadius = 0 } }
  local window = env.native.newWindow(31)
  window.width, window.height = 800, 600
  local panel = env.panels:fromWindow(env.owner, window, {
    pose = lovr.math.newMat4():translate(0, 0, -2),
    height = 1,
  })
  local flatX = panel:raycast(vector.pack(0.5, 0, 0), vector.pack(0, 0, -1))
  expect.near(flatX, (0.5 + panel.width / 2) / panel.width * 800, 1e-3, 'the flat pixel')
  expect.truthy(panel:setCurve(1, true), 'the runtime curve applies')
  expect.near(panel.curve, 1, 1e-9, 'the panel owns the curve')
  local curvedX = panel:raycast(vector.pack(0.5, 0, 0), vector.pack(0, 0, -1))
  expect.truthy(curvedX, 'the curved face is hit')
  expect.truthy(math.abs(curvedX - flatX) > 1, 'the arc moves the source pixel')
  expect.near(curvedX, (panel.width / 2 + math.atan2(0.5, math.sqrt(0.75))) / panel.width * 800, 1e-2, 'the arc pixel')

  local monitor = env.native.newMonitor 'curved-screen'
  local mirror = env.panels:fromMonitor(env.owner, monitor, {
    pose = lovr.math.newMat4():translate(0, 0, -2),
    height = 1,
  })
  local mirrorFlat = mirror:raycast(vector.pack(0.5, 0, 0), vector.pack(0, 0, -1))
  expect.truthy(mirror:setCurve(1, true), 'a monitor curves too')
  local mirrorCurved = mirror:raycast(vector.pack(0.5, 0, 0), vector.pack(0, 0, -1))
  expect.truthy(mirrorCurved and mirrorCurved ~= mirrorFlat, 'the monitor arc moves the pixel')
  env.session:close()
end)

test('a curve preview is silent and a commit always notifies', function()
  local env = start()
  local panel = env.panels:fromWindow(env.owner, env.native.newWindow(32))
  local changes: { number } = {}
  env.panels:onCurveChanged(env.owner, {
    run = function(changed: contract.Panel)
      expect.equal(changed, panel, 'the changed panel')
      changes[#changes + 1] = changed.curve
    end,
  })
  expect.truthy(panel:setCurve(0.5), 'the preview applies')
  expect.near(panel.curve, 0.5, 1e-9, 'the preview curve')
  expect.equal(#changes, 0, 'the preview does not notify')
  expect.falsy(panel:setCurve(0.5), 'an unchanged preview does nothing')
  expect.truthy(panel:setCurve(0.5, true), 'an unchanged commit still notifies')
  expect.equal(changes[1], 0.5, 'the committed curve')
  expect.truthy(panel:setCurve(0.25, true), 'a changed commit notifies')
  expect.equal(#changes, 2, 'two commits')
  expect.raises(function()
    panel:setCurve(-1)
  end, nil, 'a negative curve is refused')
  env.session:close()
end)

test('a transform lock is panel state and notifies on a transition', function()
  local env = start()
  local panel = env.panels:fromWindow(env.owner, env.native.newWindow(33))
  local changes = 0
  env.panels:onTransformLockChanged(env.owner, {
    run = function(changed: contract.Panel)
      expect.equal(changed, panel, 'the changed panel')
      changes += 1
    end,
  })
  expect.falsy(panel.transformLocked, 'unlocked by default')
  expect.truthy(panel:setTransformLocked(env.owner, true), 'the lock applies')
  expect.truthy(panel.transformLocked, 'the surface publishes the lock')
  expect.falsy(panel:setTransformLocked(env.owner, true), 'an unchanged lock does not notify')
  expect.equal(changes, 1, 'one transition')
  expect.truthy(panel:setTransformLocked(env.other, false), 'another live owner may unlock')
  expect.equal(changes, 2, 'the unlock notifies')
  env.session:close()
end)

test('a curved target detaches the joined outline', function()
  local env = start { style = { windowRadius = 0 } }
  local panel = env.panels:fromWindow(env.owner, env.native.newWindow(34), { height = 1 })
  local attachment = panel:attachFrame(env.owner, {
    headerHeight = 0.1,
    headerRadius = 0.02,
    borderThickness = 0.001,
    borderDepth = 0.01,
    borderColor = { 1, 1, 1, 1 },
  })
  expect.truthy(attachment:isJoined(), 'a flat panel joins its outline')
  panel:setCurve(0.5, true)
  expect.falsy(attachment:isJoined(), 'a curved panel draws its own chrome')
  attachment:dispose()
  env.session:close()
end)

return test

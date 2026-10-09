local testing = require '@testing'
local expect = testing.expect
local contract = require '@lunette-contracts/panels'

local test = testing.suite()

local function start(config)
  local env = { native = testing.native() }
  env.session = testing.start {
    'theme',
    { id = 'panels', definition = require('@lunette-plugins/panels').definition, config = config },
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
  local added, removed, everything = {}, {}, {}
  env.panels:onAdded(env.owner, function(created)
    added[#added + 1] = created
  end)
  env.panels:onAdded(env.owner, function()
    error 'arrival listener failed'
  end)
  local first = env.panels:fromWindow(env.owner, env.native.newWindow(1), { height = 1 })
  local second = env.panels:fromWindow(env.owner, env.native.newWindow(2), { height = 1 })
  expect.equal(added[1], first, 'the first arrival')
  expect.equal(#added, 2, 'the arrivals heard')
  env.panels:onRemoved(env.owner, {
    panel = first,
    run = function(target)
      removed[#removed + 1] = target
    end,
  })
  env.panels:onRemoved(env.owner, {
    run = function(target)
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
  local panel = env.panels:fromWindow(env.owner, env.native.newWindow(1), { height = 1 })
  local claim = panel.claim
  local hiding = panel:setHidden(env.owner, { hidden = true })
  expect.truthy(panel.hidden, 'the hidden panel')
  expect.truthy(claim.dead, 'hiding gives up the layer claim')
  expect.equal(panel:raycast(vector.pack(0, 0, 0), vector.pack(0, 0, -1)), nil, 'a hidden panel is not picked')
  local showing = panel:setHidden(env.other, { hidden = false })
  expect.falsy(panel.hidden, 'the newer override shows the panel')
  hiding:dispose()
  showing:dispose()
  expect.falsy(panel.hidden, 'with no override the panel is shown')
  env.panels:update()
  expect.truthy(panel.claim and not panel.claim.dead, 'a shown panel claims again')
  env.session:close()
end)

return test

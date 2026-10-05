local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local layoutsContract = require '@lunette-contracts/layouts'

local test = testing.suite()

local function start()
  local env = { native = testing.native() }
  env.session = testing.start { 'layouts', 'layout/arc' }
  local observed = env.session:observe(layoutsContract.capability)
  env.layouts, env.owner = observed.service, observed.context
  return env
end

local function probe(env, name)
  local found = {}
  found.instance = env.session:use(plugin.define {
    name = name,
    requires = { layouts = layoutsContract.capability },
    init = function(context)
      found.owner = context
      found.layouts = context:require(layoutsContract.capability)
    end,
  })
  return found
end

local function moving(width)
  local panel = { dead = false, width = width }
  function panel:setPose(pose)
    self.pose = pose
  end
  return panel
end

test('a registration is checked, and a name is one registration', function()
  local env = start()
  expect.equal(table.concat(env.layouts:names(), ','), 'arc', 'the registered layouts')
  expect.raises(function()
    env.layouts:register(env.owner, { name = 'x', fn = function() end })
  end, 'layouts register: unknown field fn; the fields are name, apply, and continuous', 'an unknown field')
  expect.raises(function()
    env.layouts:register(env.owner, { name = 'x', apply = function() end, continuous = 1 })
  end, 'layouts register: continuous is a boolean', 'a continuous flag that is not a boolean')
  expect.raises(function()
    env.layouts:register(env.owner, { name = 'arc', apply = function() end })
  end, 'layouts register: arc is already registered', 'a registered name')
  env.session:close()
end)

test('a change listener hears registrations begin and end, and a raising one does not stop the next', function()
  local env = start()
  local heard = 0
  env.layouts:onChanged(env.owner, {
    run = function()
      error 'a raising change listener'
    end,
  })
  env.layouts:onChanged(env.owner, {
    run = function()
      heard += 1
    end,
  })
  -- A separate owner retains registration authority during listener effect disposal.
  local registrar = probe(env, 'layouts-registrar')
  local stack = registrar.layouts:register(registrar.owner, { name = 'stack', apply = function() end })
  expect.equal(heard, 1, 'the registration is heard')
  local reported = env.native.events.reported
  expect.equal(#reported, 1, 'the reports')
  expect.truthy(reported[1].message:find('layouts: a change listener', 1, true), reported[1].message)
  expect.truthy(reported[1].message:find('a raising change listener', 1, true), reported[1].message)
  stack:dispose()
  expect.equal(heard, 2, 'the end of the registration is heard')
  expect.equal(env.layouts:get 'stack', nil, 'the disposed registration')
  env.session:close()
end)

test('get answers a frozen entry, and nothing for a name not registered', function()
  local env = start()
  env.layouts:register(env.owner, { name = 'stack', apply = function() end })
  local entry = env.layouts:get 'stack'
  expect.equal(entry.name, 'stack', 'the name')
  expect.equal(entry.continuous, false, 'continuous defaults to false')
  expect.truthy(table.isfrozen(entry), 'the entry is frozen')
  expect.equal(env.layouts:get 'missing', nil, 'a name not registered')
  env.session:close()
end)

test('apply passes the live panels and the options, and names the layouts for an unknown name', function()
  local env = start()
  local seen
  env.layouts:register(env.owner, {
    name = 'stack',
    apply = function(panels, options)
      seen = { count = #panels, options = options }
    end,
  })
  local dead = moving(1)
  dead.dead = true
  env.layouts:apply { name = 'stack', panels = { moving(1), dead, moving(1) }, options = { depth = 2 } }
  expect.equal(seen.count, 2, 'the live panels')
  expect.equal(seen.options.depth, 2, 'the options')
  expect.raises(function()
    env.layouts:apply { name = 'grid', panels = {} }
  end, 'layouts apply: no layout is registered as grid; the layouts are arc, stack', 'an unknown name')
  env.session:close()
end)

test("a layout's own option error raises from apply", function()
  local env = start()
  expect.raises(function()
    env.layouts:apply { name = 'arc', panels = { moving(1) }, options = { radious = 1 } }
  end, 'plugin layout/arc: option radious is not a declared field', 'an unknown arc option')
  env.session:close()
end)

test('a registration ends with its owner, and the name is free again', function()
  local env = start()
  local owned = probe(env, 'layouts-owned')
  owned.layouts:register(owned.owner, { name = 'owned', apply = function() end, continuous = true })
  expect.equal(env.layouts:get('owned').continuous, true, 'the continuous registration')
  owned.instance:disable()
  expect.equal(env.layouts:get 'owned', nil, 'the registration after its owner ends')
  env.layouts:register(env.owner, { name = 'owned', apply = function() end })
  expect.truthy(env.layouts:get 'owned', 'the name registered again')
  env.session:close()
end)

return test

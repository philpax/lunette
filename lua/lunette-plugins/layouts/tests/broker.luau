local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
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
  found.instance = env.session:use(adapter.define {
    name = name,
    requires = { layoutsContract.capability },
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

test('a change listener hears registrations begin and end, and a name is one registration', function()
  local env = start()
  local heard = 0
  env.layouts:onChanged(env.owner, {
    run = function()
      heard += 1
    end,
  })
  -- A separate owner retains registration authority during listener effect disposal.
  local registrar = probe(env, 'layouts-registrar')
  local stack = registrar.layouts:register(registrar.owner, { name = 'stack', apply = function() end })
  expect.equal(heard, 1, 'the registration is heard')
  expect.raises(function()
    env.layouts:register(env.owner, { name = 'stack', apply = function() end })
  end, 'layouts register: stack is already registered', 'a registered name')
  stack:dispose()
  expect.equal(heard, 2, 'the end of the registration is heard')
  expect.equal(env.layouts:get 'stack', nil, 'the disposed registration')

  local owned = probe(env, 'layouts-owned')
  owned.layouts:register(owned.owner, { name = 'owned', apply = function() end, continuous = true })
  expect.equal(env.layouts:get('owned').continuous, true, 'the continuous registration')
  owned.instance:disable()
  expect.equal(env.layouts:get 'owned', nil, 'the registration after its owner ends')
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
  end, 'layout/arc: option radious is not a declared field', 'an unknown arc option')
  env.session:close()
end)

return test

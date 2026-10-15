local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local layoutsContract = require '@lunette-contracts/layouts'

local test = testing.suite()

type Environment = {
  native: testing.Native,
  session: testing.Session,
  layouts: layoutsContract.Service?,
  owner: plugin.Context?,
}
type Probe = { owner: plugin.Context?, layouts: layoutsContract.Service?, instance: adapter.Instance<{}>? }
type MovingPanel = { dead: boolean, width: number, pose: Mat4?, setPose: (MovingPanel, Mat4) -> () }

local function start(): Environment
  local env: Environment = { native = testing.native() }
  env.session = testing.start { 'layouts', 'layout/arc' }
  local observed = env.session:observe(layoutsContract.capability)
  env.layouts, env.owner = observed.service, observed.context
  return env
end

local function probe(env: Environment, name: string): Probe
  local found: Probe = {}
  found.instance = env.session:use(adapter.define {
    name = name,
    requires = { layoutsContract.capability },
    init = function(context: plugin.Context)
      found.owner = context
      found.layouts = context:require(layoutsContract.capability)
    end,
  })
  return found
end

local function moving(width: number): MovingPanel
  local panel: MovingPanel = { dead = false, width = width }
  function panel:setPose(pose: Mat4)
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

test('apply passes the live panels, and names the layouts for an unknown name', function()
  local env = start()
  local seen: number?
  env.layouts:register(env.owner, {
    name = 'stack',
    apply = function(panels: { read [number]: layoutsContract.Panel })
      seen = #panels
    end,
  })
  local dead = moving(1)
  dead.dead = true
  env.layouts:apply { name = 'stack', panels = { moving(1), dead, moving(1) } }
  expect.equal(seen, 2, 'the live panels')
  expect.raises(function()
    env.layouts:apply { name = 'grid', panels = {} }
  end, 'layouts apply: no layout is registered as grid; the layouts are arc, stack', 'an unknown name')
  env.session:close()
end)

return test

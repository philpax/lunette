local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local dropsContract = require '@lunette-contracts/drops'
local interactionContract = require '@lunette-contracts/interaction'

local test = testing.suite()

local function start()
  local env = { native = testing.native() }
  env.session = testing.start { 'drops', 'focus', 'interaction' }
  env.consumer = env.session:use(plugin.define {
    name = 'drops-test',
    requires = { drops = dropsContract.capability, interaction = interactionContract.capability },
    init = function(context)
      env.drops = context:require(dropsContract.capability)
      env.interaction = context:require(interactionContract.capability)
      env.owner = context
    end,
  })
  env.pointer = env.interaction:newPointer(env.owner)
  return env
end

local function surface(x)
  local result = { dead = false, pose = lovr.math.newMat4():translate(x or 0, 0, 0), width = 1, height = 1 }
  function result:setPose(pose)
    self.pose:set(pose)
  end
  function result:raycast()
    return nil, nil, nil
  end
  return result
end

test('listeners hear every drop in registration order, and a disposed listener hears none', function()
  local env = start()
  local first, second = surface(), surface()
  local heard = {}
  local all = env.drops:onDropped(env.owner, {
    run = function(drop)
      expect.equal(drop.pointer, env.pointer, 'the delivered pointer')
      heard[#heard + 1] = if drop.surface == first then 'first' else 'second'
    end,
  })
  local later = env.drops:onDropped(env.owner, {
    run = function()
      heard[#heard + 1] = 'later'
    end,
  })
  env.drops:emit(env.owner, { surface = first, pointer = env.pointer })
  expect.equal(table.concat(heard, ' '), 'first later', 'the first drop')
  all:dispose()
  env.drops:emit(env.owner, { surface = second, pointer = env.pointer })
  expect.equal(table.concat(heard, ' '), 'first later later', 'after the first disposal')
  later:dispose()
  env.drops:emit(env.owner, { surface = first, pointer = env.pointer })
  expect.equal(#heard, 3, 'after both disposals')
  env.session:close()
end)

test('a drop is emitted when a grab ends, while the pointer still names the surface it carried', function()
  local env = start()
  local carried = surface()
  local heard = {}
  env.drops:onDropped(env.owner, {
    run = function(drop)
      heard[#heard + 1] = drop
      expect.equal(drop.pointer.grabbed, carried, 'what the pointer let go of')
    end,
  })
  expect.truthy(env.pointer:beginGrab(carried, lovr.math.newMat4()), 'the grab')
  expect.truthy(env.pointer:endGrab(), 'ending a grab answers that something was carried')
  expect.equal(#heard, 1, 'the drops heard')
  expect.equal(heard[1].surface, carried, 'the dropped surface')
  expect.equal(heard[1].pointer, env.pointer, 'the dropping pointer')
  expect.equal(env.pointer.grabbed, nil, 'the pointer after the drop')
  expect.falsy(env.pointer:endGrab(), 'nothing is carried twice')
  expect.equal(#heard, 1, 'the drops heard after the second end')
  env.session:close()
end)

return test

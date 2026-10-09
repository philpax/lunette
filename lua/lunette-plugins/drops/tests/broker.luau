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

test('a malformed listener raises at the call', function()
  local env = start()
  local first = surface()
  expect.raises(function()
    env.drops:onDropped(env.owner, { run = function() end, panel = first })
  end, nil, 'an unknown listener field')
  expect.raises(function()
    env.drops:onDropped(env.owner, { run = 'no' })
  end, nil, 'a run that is not a function')
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
  expect.raises(function()
    heard[1].surface = surface()
  end, nil, 'a delivered drop is frozen')
  env.session:close()
end)

test('a listener that raises is reported, and the listeners after it still run', function()
  local env = start()
  local after = 0
  env.drops:onDropped(env.owner, {
    run = function()
      error 'drop listener failure'
    end,
  })
  env.drops:onDropped(env.owner, {
    run = function()
      after += 1
    end,
  })
  local carried = surface()
  expect.truthy(env.pointer:beginGrab(carried, lovr.math.newMat4()), 'the grab')
  expect.truthy(env.pointer:endGrab(), 'the drop')
  expect.equal(after, 1, 'the listener after a raising one')
  local reported = env.native.events.reported
  expect.equal(#reported, 1, 'the reports')
  expect.truthy(reported[1].message:find('drop listener failure', 1, true), 'the reported failure')
  env.session:close()
end)

test('a listener disposed by an earlier listener of the same drop is skipped', function()
  local env = start()
  local calls = 0
  local canceled
  env.drops:onDropped(env.owner, {
    run = function()
      canceled:dispose()
    end,
  })
  canceled = env.drops:onDropped(env.owner, {
    run = function()
      calls += 1
    end,
  })
  env.drops:emit(env.owner, { surface = surface(), pointer = env.pointer })
  expect.equal(calls, 0, 'the calls of the disposed listener')
  env.session:close()
end)

test("an unloading owner's listeners are not called while its effects unwind", function()
  local env = start()
  local calls = 0
  local unloadingOwner
  local unloading = env.session:use(plugin.define {
    name = 'drops-test-unloading',
    requires = { drops = dropsContract.capability },
    init = function(context)
      unloadingOwner = context
    end,
  })
  env.drops:onDropped(unloadingOwner, {
    run = function()
      calls += 1
    end,
  })
  unloadingOwner:effect(function()
    return function()
      env.drops:emit(env.owner, { surface = surface(), pointer = env.pointer })
    end
  end)
  unloading:disable()
  expect.equal(calls, 0, 'the calls while unloading')
  env.session:close()
end)

test('a stale owner cannot emit, and a stale provider rejects registration', function()
  local env = start()
  local stale = env.owner
  env.consumer:disable()
  expect.raises(function()
    env.drops:emit(stale, { surface = surface(), pointer = env.pointer })
  end, nil, 'the stale owner')
  env.consumer:enable()
  local owner, drops = env.owner, env.drops
  env.consumer:disable()
  env.session.instances.interaction:disable()
  env.session.instances.drops:disable()
  expect.raises(function()
    drops:onDropped(owner, { run = function() end })
  end, nil, 'the stale provider')
  env.session:close()
end)

test('a disposed listener does not retain what it captured', function()
  local env = start()
  local weak = setmetatable({}, { __mode = 'v' })
  for index = 1, 32 do
    do
      local payload = { index = index }
      weak[index] = payload
      local effect = env.drops:onDropped(env.owner, {
        run = function()
          expect.equal(payload.index, index, 'the captured payload')
        end,
      })
      effect:dispose()
    end
    testing.collect()
    testing.collect()
    expect.equal(weak[index], nil, 'the capture of a disposed listener')
  end
  env.session:close()
end)

return test

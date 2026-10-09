local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/focus'
local frame = require '@lunette-contracts/frame'
local test = testing.suite()

local function start()
  local env = { native = testing.native(), heard = {} }
  env.session = testing.boot({ 'frame', 'focus' }, { native = env.native })
  env.first = env.session:observe(contract.capability)
  env.second = env.session:observe(contract.capability)
  env.focus, env.owner, env.other = env.first.service, env.first.context, env.second.context
  local function seat(id)
    local value = { id = id, dead = false, calls = {} }
    function value:setFocus(sink)
      self.calls[#self.calls + 1] = { sink = sink }
      if self.refuse then
        return false
      end
      self.focus = sink
      return true
    end
    return value
  end
  env.left, env.right = seat(11), seat(12)
  env.sink, env.otherSink = { dead = false, domain = 'window', id = 1 }, { dead = false, domain = 'window', id = 2 }
  for _, sink in { env.sink, env.otherSink } do
    sink.key = function()
      return true
    end
    sink.modifiers = function()
      return true
    end
  end
  function env:nativeTarget(owner, seatValue, sink)
    return self.focus:register(owner, { kind = 'native', seat = seatValue, sink = sink })
  end
  function env:localTarget(receiver, owner)
    return self.focus:register(owner or self.owner, {
      kind = 'local',
      wantsKeyboard = true,
      receiver = receiver or {
        key = function()
          return false
        end,
        text = function()
          return false
        end,
      },
    })
  end
  env.focus:onChanged(env.owner, {
    run = function(change)
      env.heard[#env.heard + 1] = change
    end,
  })
  return env
end

test('focus single route and nonrestoring disposal', function()
  local env = start()
  local app = env:nativeTarget(env.owner, env.left, env.sink)
  local field = env:localTarget()
  expect.truthy(app:focus(), 'the application focuses')
  expect.equal(env.left.focus, env.sink, 'native window focus is established')
  expect.equal(env.focus:focused(), app, 'the registered route is current')
  local revision = env.focus:revision()
  expect.truthy(app:focus(), 'refocusing the same handle succeeds')
  expect.equal(env.focus:revision(), revision, 'idempotent focus')
  expect.truthy(field:focus(), 'the local field focuses')
  expect.equal(env.left.focus, nil, 'local input clears only the former native seat')
  expect.equal(env.heard[#env.heard].target, field, 'the change identifies the new route')
  expect.truthy(env.heard[#env.heard].wantsKeyboard, 'immutable visibility intent')
  expect.raises(function()
    env.heard[#env.heard].revision = 0
  end, nil, 'change data is frozen')
  app:destroy()
  expect.equal(env.focus:focused(), field, 'old disposal does not clear the field')
  field:destroy()
  expect.equal(env.focus:focused(), nil, 'no prior application is restored')
  expect.truthy(field.dead, 'the field is invalidated')
  expect.falsy(field:focus(), 'retained dead handles stay inert')
  env.session:close()
end)

test('independent native seat authority survives global route changes', function()
  local env = start()
  local first = env:nativeTarget(env.owner, env.left, env.sink)
  local second = env:nativeTarget(env.owner, env.right, env.otherSink)
  first:focus()
  second:focus()
  expect.equal(env.left.focus, env.sink, 'the first seat retains native authority')
  second:destroy()
  expect.equal(env.right.focus, nil, 'the destroyed seat clears')
  expect.equal(env.left.focus, env.sink, 'the other seat remains independent')
  expect.equal(env.focus:focused(), nil, 'disposal does not restore the earlier route')
  first:destroy()
  expect.equal(env.left.focus, nil, 'a noncurrent authoritative target still clears its seat')
  env.session:close()
end)

test('superseded handles cannot clear a newer holder of the same native seat', function()
  local env = start()
  local first = env:nativeTarget(env.owner, env.left, env.sink)
  local second = env:nativeTarget(env.other, env.left, env.otherSink)
  first:focus()
  second:focus()
  first:destroy()
  expect.equal(env.left.focus, env.otherSink, 'an older target cannot withdraw newer native authority')
  env.second.instance:disable()
  expect.equal(env.left.focus, nil, 'owner unload clears current authority')
  expect.equal(env.focus:focused(), nil, 'owner unload clears the current route')
  expect.truthy(second.dead, 'owner unload invalidates the target')
  env.session:close()
end)

test('focus reentrant generation isolation', function()
  local env = start()
  local last = env:localTarget()
  local second = env:localTarget {
    key = function()
      return false
    end,
    text = function()
      return false
    end,
    onFocus = function()
      error 'a superseded field cannot receive focus'
    end,
  }
  local first = env:localTarget {
    key = function()
      return false
    end,
    text = function()
      return false
    end,
    onBlur = function()
      last:focus()
    end,
  }
  first:focus()
  second:focus()
  expect.equal(env.focus:focused(), last, 'the reentrant route wins')
  expect.equal(env.heard[#env.heard].target, last, 'public notifications do not resume an old generation')
  env.session:close()
end)

test('false window focus refuses a route without changing the previous state', function()
  local env = start()
  local localTarget = env:localTarget()
  localTarget:focus()
  local revision = env.focus:revision()
  env.left.refuse = true
  local app = env:nativeTarget(env.owner, env.left, env.sink)
  expect.falsy(app:focus(), 'native focus refusal propagates')
  expect.equal(env.focus:focused(), localTarget, 'the earlier live route remains current')
  expect.equal(env.focus:revision(), revision, 'no refused transition is announced')
  env.session:close()
end)

test('destroy invalidates callbacks before notification and reports native inverse refusal', function()
  local env = start()
  local callback = 0
  local field = env:localTarget {
    key = function()
      return false
    end,
    text = function()
      return false
    end,
    onBlur = function()
      callback += 1
    end,
  }
  field:focus()
  field:destroy()
  expect.equal(callback, 0, 'destroyed receiver callbacks are cleared')
  local app = env:nativeTarget(env.owner, env.left, env.sink)
  app:focus()
  env.left.refuse = true
  app:destroy()
  expect.equal(env.focus:focused(), nil, 'inverse refusal does not resurrect a route')
  local reports = env.native.events.reported
  expect.equal(#reports, 1, 'the inverse refusal is reported')
  expect.truthy(reports[1].message:find('refused focus clear', 1, true), reports[1].message)
  env.session:close()
end)

test('a listener error is reported and later listeners still receive the committed route', function()
  local env = start()
  local after = 0
  local failing = env.focus:onChanged(env.owner, {
    run = function()
      error 'focus listener failure'
    end,
  })
  env.focus:onChanged(env.owner, {
    run = function()
      after += 1
    end,
  })
  local field = env:localTarget()
  field:focus()
  expect.equal(after, 1, 'the later listener runs')
  local reports = env.native.events.reported
  expect.equal(#reports, 1, 'the callback failure is reported')
  expect.truthy(reports[1].message:find('focus listener failure', 1, true), reports[1].message)
  failing:dispose()
  env.session:close()
end)

test('native target loss clears route and modifier intent at the next input boundary', function()
  local env = start()
  local app = env:nativeTarget(env.owner, env.left, env.sink)
  app:focus()
  local revision = env.focus:revision()
  env.sink.dead = true
  env.session:update()
  expect.equal(env.focus:revision(), revision + 1, 'loss is announced without an explicit focus getter')
  expect.equal(env.heard[#env.heard].kind, 'none', 'the native loss clears input intent')
  expect.equal(env.left.focus, nil, 'native focus is withdrawn')
  env.session:close()
end)

test('native focus cleanup refusal blocks delivery to the committed replacement route', function()
  local env = start()
  local deliveries = 0
  local app = env:nativeTarget(env.owner, env.left, env.sink)
  local field = env:localTarget {
    key = function()
      deliveries += 1
      return true
    end,
    text = function()
      deliveries += 1
      return true
    end,
  }
  local input = env.focus:newSource(env.owner)
  app:focus()
  env.left.refuse = true
  expect.falsy(field:focus(), 'the failed inverse is reported as refusal')
  expect.equal(env.focus:focused(), field, 'committed arbiter state is not rolled back')
  expect.equal(#env.native.events.reported, 1, 'focus cleanup failure is reported')
  expect.equal(input:text('safe').kind, 'refused', 'unresolved cleanup prevents unsafe continuation')
  expect.equal(deliveries, 0, 'the replacement cannot receive input after unsafe native cleanup')
  expect.truthy(env.focus:inspect().state.failed, 'the failure remains inspectable')
  env.session:close()
end)

test('target loss discovered during selection blocks the same operation after native cleanup refusal', function()
  local env = start()
  local deliveries = 0
  local first = env:nativeTarget(env.owner, env.left, env.sink)
  local second = env:nativeTarget(env.owner, env.right, env.otherSink)
  first:focus()
  second:focus()
  local field = env:localTarget {
    key = function()
      return false
    end,
    text = function()
      deliveries += 1
      return true
    end,
  }
  field:focus()
  local input = env.focus:newSource(env.owner)
  env.left.refuse = true
  env.sink.dead = true
  expect.equal(input:text('unsafe').kind, 'refused', 'selection-time failure blocks the in-flight operation')
  expect.equal(deliveries, 0, 'the local callback never runs')
  expect.equal(#env.native.events.reported, 1, 'the failed focus inverse is reported')
  env.session:close()
end)

return test

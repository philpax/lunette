-- Covers runtime collection, close, and host shutdown.
-- Shutdown cases run last because shutdown retires every runtime in the state.
local testing = require '@testing'
local expect = testing.expect
local plugin = require('@lunette').plugin

local test = testing.suite()

test('an active instance survives the collection of its runtime userdata', function()
  local escaped
  local definition = plugin.define({}, {}, function(context)
    escaped = context
    context:effect(function()
      return function() end
    end)
    return {}
  end)
  local runtime = plugin.runtime()
  runtime:use(definition, {}):enable()
  runtime = nil
  testing.collect()
  expect.truthy(escaped:active(), 'the context after its runtime was collected')
end)

test('close releases every effect, ahead of the request queue and its action limits', function()
  local released = 0
  local definition = plugin.define({}, {}, function(context)
    context:effect(function()
      return function()
        released += 1
      end
    end)
    return {}
  end)
  local runtime = plugin.runtime()
  for _ = 1, 300 do
    runtime:use(definition, {}):enable()
  end
  runtime:close()
  expect.equal(released, 300, 'the effects released by close')

  local other = plugin.runtime()
  local pending = {}
  for index = 1, 300 do
    pending[index] = other:use(definition, {})
  end
  other
    :use(
      plugin.define({}, {}, function(context)
        context:effect(function()
          return function()
            released += 1
          end
        end)
        for index = 1, 300 do
          pcall(function()
            pending[index]:enable()
          end)
        end
        other:close()
        return {}
      end),
      {}
    )
    :enable()
  expect.equal(released, 301, 'the close queued behind 300 requests keeps its priority')
  expect.raises(function()
    other:use(definition, {})
  end, nil, 'using the closed runtime')
end)

test('close releases every child before its parent', function()
  local count = 300
  local runtime = plugin.runtime()
  local released = {}
  local parentReleased = 0
  local child = plugin.define({}, {}, function(context, config)
    context:effect(function()
      return function()
        expect.equal(parentReleased, 0, 'the parent remains live during child cleanup')
        released[config.index] = (released[config.index] or 0) + 1
      end
    end)
    return {}
  end)
  local parent = runtime:use(
    plugin.define({}, {}, function(context)
      context:effect(function()
        return function()
          parentReleased += 1
          for index = 1, count do
            expect.equal(released[index], 1, 'each child releases before its parent')
          end
        end
      end)
      for index = 1, count do
        context:child(child, { index = index }):enable()
      end
      return {}
    end),
    {}
  )
  parent:enable()
  runtime:close()
  expect.equal(parentReleased, 1, 'the parent inverse')
  for index = 1, count do
    expect.equal(released[index], 1, 'the child inverse')
  end
end)

test('an interrupted close retains pending inverses for the next drain', function()
  local runtime = plugin.runtime()
  local released = 0
  local keeper = plugin.define({}, {}, function(context)
    context:effect(function()
      return function()
        released += 1
      end
    end)
    return {}
  end)
  runtime:use(keeper, {}):enable()
  runtime:use(keeper, {}):enable()
  local attempts = 0
  local cycling
  cycling = runtime:use(
    plugin.define({}, {}, function(context)
      attempts += 1
      context:effect(function()
        return function() end
      end)
      -- Three instances give the drain 88 actions; close starts at its final action.
      if attempts == 88 then
        runtime:close()
      else
        cycling:reload {}
      end
      return {}
    end),
    {}
  )
  expect.raises(function()
    cycling:enable()
  end, 'plugin drain: stopped after', 'the bounded drain')
  expect.raises(function()
    runtime:use(keeper, {})
  end, 'the runtime is closed', 'a closing runtime accepts no instances')
  runtime:drain()
  expect.equal(released, 2, 'the resumed close releases both keepers')
  runtime:close()
  expect.equal(released, 2, 'close repeats no inverse')
end)

test('the plugin shutdown releases a leaked effect payload', function()
  local definition = plugin.define({}, {}, function(context, config)
    context:effect(function()
      return function()
        config.released = true
      end
    end)
    return {}
  end)
  local payload = { released = false }
  plugin.runtime():use(definition, payload):enable()
  expect.falsy(payload.released, 'the payload before shutdown')
  expect.equal(#testing.host.shutdown(), 0, 'the failures of the shutdown')
  expect.truthy(payload.released, 'the payload after shutdown')
end)

return test

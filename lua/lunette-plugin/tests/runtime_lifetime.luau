-- Covers runtime collection, close, and host shutdown.
-- Shutdown cases run last because shutdown retires every runtime in the state.
local testing = require '@testing'
local expect = testing.expect
local plugin = require('@lunette').plugin

local test = testing.suite()

type NativeContext = testing.NativeContext
type NativeRuntime = testing.NativeRuntime

test('an active instance survives the collection of its runtime userdata', function()
  local escaped: NativeContext?
  local definition = plugin.define({}, {}, function(context: NativeContext): {}
    escaped = context
    context:effect(function(): () -> ()
      return function() end
    end)
    return {}
  end)
  local runtime: NativeRuntime? = plugin.runtime()
  runtime:use(definition, {}):enable()
  runtime = nil
  testing.collect()
  expect.truthy(escaped:active(), 'the context after its runtime was collected')
end)

test('close releases every effect, each child before its parent', function()
  local count = 3
  local runtime = plugin.runtime()
  local released: { [number]: number } = {}
  local parentReleased = 0
  local child = plugin.define({}, {}, function(context: NativeContext, config: { index: number }): {}
    context:effect(function(): () -> ()
      return function()
        expect.equal(parentReleased, 0, 'the parent remains live during child cleanup')
        released[config.index] = (released[config.index] or 0) + 1
      end
    end)
    return {}
  end)
  local parent = runtime:use(
    plugin.define({}, {}, function(context: NativeContext): {}
      context:effect(function(): () -> ()
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

test('the plugin shutdown releases a leaked effect payload', function()
  local definition = plugin.define({}, {}, function(context: NativeContext, config: { released: boolean }): {}
    context:effect(function(): () -> ()
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

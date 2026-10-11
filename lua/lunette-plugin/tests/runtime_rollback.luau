-- Covers the native runtime rolling back a failed load, and what a cleanup may do.
local testing = require '@testing'
local expect = testing.expect
local plugin = require('@lunette').plugin

local test = testing.suite()

type NativeContext = testing.NativeContext
type NativeDefinition = testing.NativeDefinition
type Attempts = { active: boolean, effect: boolean, child: boolean, owner: boolean }

-- Attempts each acquisition a cleanup must not make, and answers which succeeded.
local function attempt(context: NativeContext, providerContext: NativeContext, child: NativeDefinition): Attempts
  return {
    active = context:active(),
    effect = pcall(function()
      context:effect(function(): () -> ()
        return function() end
      end)
    end),
    child = pcall(function()
      context:child(child, {}):enable()
    end),
    owner = pcall(function()
      providerContext:checkOwner(context)
    end),
  }
end

test('a failing load rolls back in reverse with its services readable, and a failing inverse quarantines it', function()
  local runtime = plugin.runtime()
  local dependency = plugin.contract('audit/rollback-dependency', 1)
  local events: { string } = {}
  local providerContext: NativeContext?
  runtime
    :use(
      plugin.define({}, { service = dependency }, function(context: NativeContext): { service: number }
        providerContext = context
        return { service = 42 }
      end),
      {}
    )
    :enable()
  local childLoads = 0
  local child = plugin.define({}, {}, function(): {}
    childLoads += 1
    return {}
  end)
  local loads = 0
  local attempts: { Attempts } = {}
  local instance = runtime:use(
    plugin.define({ dependency = dependency }, {}, function(context: NativeContext): never
      loads += 1
      for index = 1, 3 do
        context:effect(function(): () -> ()
          return function()
            table.insert(events, tostring(index))
            expect.equal(context:services().dependency, 42, 'the dependency during rollback')
            attempts[index] = attempt(context, providerContext, child)
            if index == 2 then
              error 'rollback inverse failure'
            end
          end
        end)
      end
      error 'rollback initializer failure'
    end),
    {}
  )
  instance:enable()
  expect.equal(table.concat(events, ','), '3,2,1', 'the inverses run in reverse, past the failing one')
  for index, made in attempts do
    expect.falsy(made.active or made.effect or made.child or made.owner, 'rollback inverse ' .. index .. ' authority')
  end
  expect.equal(childLoads, 0, 'no rollback installed a child')
  expect.equal(instance:state(), 'quarantined', 'the failed rollback')
  expect.raises(function()
    instance:enable()
  end, nil, 'enabling the quarantined instance')
  expect.equal(loads, 1, 'the failed rollback is not retried')
  local reports = testing.takeReports()
  expect.equal(#reports, 2, table.concat(reports, '\n'))
  local joined = table.concat(reports, '\n')
  expect.truthy(joined:find('rollback initializer failure', 1, true), joined)
  expect.truthy(joined:find('rollback inverse failure', 1, true), joined)
  runtime:close()
  expect.equal(table.concat(events, ','), '3,2,1', 'shutdown does not retry the rollback')
end)

test('a cleanup reads its services but acquires nothing, and an owner check accepts only the current caller', function()
  local token = plugin.contract('audit/authority', 1)
  local providerContext: NativeContext?
  local contexts: { NativeContext } = {}
  local cleanups: { Attempts } = {}
  local child = plugin.define({}, {}, function(): {}
    return {}
  end)
  local runtime = plugin.runtime()
  local provider = runtime:use(
    plugin.define({}, { service = token }, function(context: NativeContext): { service: number }
      providerContext = context
      return { service = 42 }
    end),
    {}
  )
  local consumer = runtime:use(
    plugin.define({ service = token }, {}, function(context: NativeContext): {}
      table.insert(contexts, context)
      providerContext:checkOwner(context)
      context:effect(function(): () -> ()
        return function()
          expect.equal(context:services().service, 42, 'the service during cleanup')
          table.insert(cleanups, attempt(context, providerContext, child))
        end
      end)
      return {}
    end),
    {}
  )
  provider:enable()
  consumer:enable()
  consumer:requestReload {}
  runtime:drain()
  expect.equal(#contexts, 2, 'the activations')
  expect.raises(function()
    providerContext:checkOwner(contexts[1])
  end, nil, 'the owner check on the old caller')
  runtime:close()
  expect.equal(#cleanups, 2, 'the cleanups')
  for index, made in cleanups do
    expect.falsy(made.active or made.effect or made.child or made.owner, 'cleanup ' .. index .. ' authority')
  end
end)

test('an acquisition that yields fails the load', function()
  local definition = plugin.define({}, {}, function(context: NativeContext): {}
    context:effect(function(): () -> ()
      coroutine.yield()
      return function() end
    end)
    return {}
  end)
  local runtime = plugin.runtime()
  local instance = runtime:use(definition, {})
  instance:enable()
  expect.equal(instance:state(), 'failed', 'the yielding load')
  local reports = testing.takeReports()
  expect.equal(#reports, 1, table.concat(reports, '\n'))
  expect.truthy(string.find(reports[1], 'yield', 1, true), reports[1])
  runtime:close()
end)

return test

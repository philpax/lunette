local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'

local test = testing.suite()

for _, mode in { 'dispose', 'disable', 'reload', 'close' } do
  test('a returned resource releases once on ' .. mode, function()
    local runtime = plugin.runtime()
    local values = {}
    local effects = {}
    local releases = 0
    local instance = runtime:use(
      plugin.define {
        name = 'resource-owner',
        init = function(context)
          local value, effect = context:resource(context, function()
            local acquired = { dead = false }
            return acquired, function()
              acquired.dead = true
              releases += 1
            end
          end)
          table.insert(values, value)
          table.insert(effects, effect)
          expect.falsy(value.dead, 'the registered value is live')
        end,
      },
      {}
    )
    instance:enable()
    expect.equal(instance:state(), 'active', tostring(instance:diagnostic()))
    if mode == 'dispose' then
      effects[1]:dispose()
    elseif mode == 'disable' then
      instance:disable()
    elseif mode == 'reload' then
      instance:reload {}
    else
      runtime:close()
    end
    expect.truthy(values[1].dead, 'the first value is released')
    expect.equal(releases, 1, 'the first inverse runs once')
    effects[1]:dispose()
    expect.equal(releases, 1, 'disposal repeats no inverse')
    runtime:close()
    expect.equal(releases, #values, 'each successful acquisition releases once')
  end)
end

for _, cancel in { false, true } do
  test('a resource answers no value after ' .. (if cancel then 'cancellation' else 'acquisition failure'), function()
    local runtime = plugin.runtime()
    local instance
    local context
    local released = 0
    instance = runtime:use(
      plugin.define {
        name = 'interrupted-resource-owner',
        init = function(owner)
          context = owner
        end,
      },
      {}
    )
    instance:enable()
    local returned = false
    expect.raises(function()
      context:resource(context, function()
        if not cancel then
          error 'resource acquisition failure'
        end
        instance:disable()
        return {}, function()
          released += 1
        end
      end)
      returned = true
    end, if cancel then 'the activation was cancelled' else 'resource acquisition failure')
    expect.falsy(returned, 'no value escapes an unsuccessful registration')
    expect.equal(released, if cancel then 1 else 0, 'only a returned inverse releases')
    runtime:close()
    expect.equal(released, if cancel then 1 else 0, 'shutdown repeats no inverse')
  end)
end

test('the resource owner is checked before acquisition', function()
  local runtime = plugin.runtime()
  local context
  local stranger
  local definition = plugin.define {
    name = 'independent-owner',
    init = function(owner, config)
      config.keep(owner)
    end,
  }
  runtime
    :use(definition, {
      keep = function(owner)
        context = owner
      end,
    })
    :enable()
  runtime
    :use(definition, {
      keep = function(owner)
        stranger = owner
      end,
    })
    :enable()
  local acquisitions = 0
  for _, owner in { stranger, {} } do
    expect.raises(function()
      context:resource(owner, function()
        acquisitions += 1
        return {}, function() end
      end)
    end)
  end
  expect.equal(acquisitions, 0, 'invalid owners run no acquisition')
  runtime:close()
end)

test('a forged resource receiver cannot bypass the owner check', function()
  local runtime = plugin.runtime()
  local provider
  local stranger
  local definition = plugin.define {
    name = 'checked-resource-receiver',
    init = function(context, config)
      config.keep(context)
    end,
  }
  runtime
    :use(definition, {
      keep = function(context)
        provider = context
      end,
    })
    :enable()
  runtime
    :use(definition, {
      keep = function(context)
        stranger = context
      end,
    })
    :enable()
  local acquired = false
  expect.raises(function()
    provider.resource(stranger, stranger, function()
      acquired = true
      return {}, function() end
    end)
  end, 'does not depend on this provider')
  expect.falsy(acquired, 'a forged receiver runs no acquisition')
  runtime:close()
end)

return test

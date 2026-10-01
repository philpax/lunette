-- A removal listener that raises while lifecycle work drains is reported, and
-- neither the drain nor the cleanup that removed the panel fails because of it.
return function()
  local lunette = require '@lunette'
  local plugin = require '@lunette-plugin'
  local contracts = require '@lunette-contracts/panels'
  local definition = require '@lunette-plugins/panels'

  local source = { id = 23, dead = false, width = 800, height = 600, title = 'Drained window', opaque = false }
  function source:getTexture()
    return false
  end

  -- The native error boundary is outside this test, so its entry point
  -- records what the provider reports.
  local reported = {}
  lunette.reportError = function(context, message)
    reported[#reported + 1] = context .. ': ' .. message
  end

  local runtime = plugin.runtime()
  local provider = runtime:use(definition, {})
  provider:enable()

  -- The creator is installed first, so a drain unloads it before the
  -- listener, and its cleanup removes the panel while the listener still hears.
  local created = 0
  local creator = runtime:use(
    plugin.define {
      name = 'removal-during-drain-1',
      requires = { panels = contracts.capability },
      init = function(context)
        local service = context:require(contracts.capability)
        service:fromWindow(context, source, { height = 1, chrome = false })
        created += 1
      end,
    },
    {}
  )
  local heard = 0
  local listener = runtime:use(
    plugin.define {
      name = 'removal-during-drain-2',
      requires = { panels = contracts.capability },
      init = function(context)
        local service = context:require(contracts.capability)
        service:onRemoved(context, nil, function()
          heard += 1
          error 'removal listener failed during a drain'
        end)
      end,
    },
    {}
  )
  listener:enable()
  creator:enable()
  assert(created == 1 and heard == 0)

  -- Reloading the provider drains both dependents, unloads and loads the
  -- provider, and loads both dependents again in one drain.
  provider:reload {}
  assert(heard == 1, 'the listener heard the removal: ' .. heard)
  assert(provider:state() == 'active', provider:state())
  assert(creator:state() == 'active', 'the drain went on past the listener: ' .. creator:state())
  assert(listener:state() == 'active', listener:state())
  assert(created == 2, 'the creator loaded again in the same drain')

  creator:disable()
  assert(heard == 2, 'the reloaded listener hears the next removal')
  assert(creator:state() == 'inactive', 'the cleanup that removed the panel succeeded: ' .. creator:state())
  assert(creator:diagnostic() == nil, tostring(creator:diagnostic()))

  assert(#reported == 2, 'each raising delivery is reported: ' .. #reported)
  for _, message in ipairs(reported) do
    assert(message:find('removal listener failed during a drain', 1, true), message)
  end
  runtime:close()
end

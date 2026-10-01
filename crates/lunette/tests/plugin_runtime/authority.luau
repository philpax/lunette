return function(plugin)
  local token = plugin.contract('audit/authority', 1)
  local provider_context
  local contexts = {}
  local runtime = plugin.runtime()
  local provider = runtime:use(
    plugin.define({}, { service = token }, function(context)
      provider_context = context
      return { service = 42 }
    end),
    {}
  )
  local cleaned = 0
  local consumer = runtime:use(
    plugin.define({ service = token }, {}, function(context)
      table.insert(contexts, context)
      provider_context:checkOwner(context)
      context:effect(function()
        return function()
          assert(context:services().service == 42, 'retained read failed')
          assert(not pcall(function()
            context:effect(function()
              return function() end
            end)
          end))
          cleaned += 1
        end
      end)
      return {}
    end),
    {}
  )
  provider:enable()
  consumer:enable()
  consumer:reload {}
  assert(#contexts == 2)
  assert(not pcall(function()
    provider_context:checkOwner(contexts[1])
  end), 'old caller accepted')
  assert(cleaned == 1, 'cleanup could not read services')
  runtime:close()
  assert(cleaned == 2)
end

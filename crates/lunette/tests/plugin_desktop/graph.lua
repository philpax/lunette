-- The shipped desktop composition built as main.lua builds it, with each
-- instance returned so a scenario can take a provider or consumer away.
local plugin = require '@lunette-plugin'
local callbacks = require 'desktop/callbacks'
local panels = require '@lunette-contracts/panels'

return function()
  local runtime = plugin.runtime()
  callbacks.install(function() end, function()
    runtime:close()
  end)
  local providers = {}
  for _, name in ipairs { 'panels', 'interaction', 'laser', 'keyboard', 'tags', 'rules', 'adoption', 'layout/arc' } do
    providers[name] = runtime:use(require('@lunette-plugins/' .. name), {})
    providers[name]:enable()
  end
  providers.display = runtime:use(require('@lunette-plugins/error-display').definition, {})
  providers.display:enable()
  local consumers = {}
  for _, name in ipairs { 'base', 'pointing', 'input', 'keyboard', 'errors' } do
    consumers[name] = runtime:use(require('desktop/' .. name), { callbacks = callbacks })
    consumers[name]:enable()
  end
  consumers.policy = runtime:use(require 'desktop/policy'(), { callbacks = callbacks })
  consumers.policy:enable()
  local desktop = { runtime = runtime, providers = providers, consumers = consumers, callbacks = callbacks }
  runtime
    :use(
      plugin.define {
        name = 'graph-1',
        requires = { panels = panels.capability },
        init = function(ctx)
          desktop.panels = ctx:require(panels.capability)
        end,
      },
      {}
    )
    :enable()
  return desktop
end

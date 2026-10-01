-- The shipped desktop composition built as main.lua builds it, with each
-- instance returned so a scenario can take a provider or consumer away.
local plugin = require '@lunette-plugin'
local frame = require '@lunette-plugins/frame'
local panels = require '@lunette-contracts/panels'
local surfaces = require '@lunette-contracts/surfaces'

return function()
  local runtime = plugin.runtime()
  frame.install {
    start = function() end,
    stop = function()
      runtime:close()
    end,
  }
  local providers = {}
  providers.frame = runtime:use(frame.definition, {})
  providers.frame:enable()
  for _, name in ipairs {
    'surfaces',
    'panels',
    'interaction',
    'laser',
    'keyboard',
    'tags',
    'rules',
    'adoption',
    'layout/arc',
  } do
    providers[name] = runtime:use(require('@lunette-plugins/' .. name), {})
    providers[name]:enable()
  end
  providers.display = runtime:use(require('@lunette-plugins/error-display').definition, {})
  providers.display:enable()
  local consumers = {}
  for _, name in ipairs { 'base', 'pointing', 'input', 'keyboard', 'errors' } do
    consumers[name] = runtime:use(require('desktop/' .. name), {})
    consumers[name]:enable()
  end
  consumers.policy = runtime:use(require 'desktop/policy'(), {})
  consumers.policy:enable()
  local desktop = { runtime = runtime, providers = providers, consumers = consumers }
  runtime
    :use(
      plugin.define {
        name = 'graph-1',
        requires = { panels = panels.capability, surfaces = surfaces.capability },
        init = function(ctx)
          desktop.panels = ctx:require(panels.capability)
          desktop.surfaces = ctx:require(surfaces.capability)
        end,
      },
      {}
    )
    :enable()
  return desktop
end

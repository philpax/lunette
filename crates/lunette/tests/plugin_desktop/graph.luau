-- The shipped desktop composition started as main.luau starts it, with each
-- instance returned so a scenario can take a provider or consumer away.
-- `options` are the composition's options, so a scenario can patch it.
local plugin = require '@lunette-plugin'
local frame = require '@lunette-plugins/frame'
local desktopRoot = require '@lunette-desktop'
local drops = require '@lunette-contracts/drops'
local panels = require '@lunette-contracts/panels'
local surfaces = require '@lunette-contracts/surfaces'

return function(options)
  local running
  frame.install {
    start = function() end,
    stop = function()
      running.runtime:close()
    end,
  }
  running = desktopRoot.start(desktopRoot.compose(options))
  local runtime = running.runtime
  local providers, consumers = {}, {}
  for id, instance in pairs(running.instances) do
    local consumer = id:match '^desktop/(.+)$'
    if consumer then
      consumers[consumer] = instance
    else
      providers[id] = instance
    end
  end
  providers.display = running.instances.errors
  local desktop = { runtime = runtime, providers = providers, consumers = consumers, instances = running.instances }
  runtime
    :use(
      plugin.define {
        name = 'graph-1',
        requires = { drops = drops.capability, panels = panels.capability, surfaces = surfaces.capability },
        init = function(ctx)
          desktop.panels = ctx:require(panels.capability)
          desktop.surfaces = ctx:require(surfaces.capability)
          desktop.drops = ctx:require(drops.capability)
          -- Announces that a grab let go of a surface, as interaction does.
          desktop.drop = function(surface)
            desktop.drops:emit(ctx, { surface = surface, pointer = {} })
          end
        end,
      },
      {}
    )
    :enable()
  return desktop
end

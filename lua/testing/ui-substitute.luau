-- Independent contract-test UI composes owner-scoped panels through public services.

local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local focus = require '@lunette-contracts/focus'
local surfaces = require '@lunette-contracts/surfaces'
local panels = require './ui-substitute/panels'
local ownerRegistry = require './ui-substitute/owner-registry'
local titlebar = require '@lunette-plugins/ui/titlebar'
local titlebarStyle = require '@lunette-plugins/ui/titlebar-style'

local substitute = {}
substitute.requires = { focus = focus.capability, surfaces = surfaces.capability }

function substitute.build(context: plugin.Context): ui.Service
  local state = {
    context = context,
    focus = context:require(focus.capability),
    panels = {},
    owners = ownerRegistry.new(context),
    generation = table.freeze { kind = 'ui-generation' },
  }
  local offers = context:require(surfaces.capability)
  local service = {}
  function state.decorate(owner, name, target, options, visible)
    return service:newTitlebar(owner, name, target, options, visible)
  end
  function service.newTitlebar(_, owner, name, target, options, visible)
    return titlebar.new(context, owner, name, target, options, visible, service, offers, titlebarStyle.DEFAULT)
  end
  function service.newPanel(_: ui.Service, owner: ui.Owner, options: ui.PanelOptions): ui.Panel
    context:checkOwner(owner)
    return panels.new(state, owner, options)
  end
  function service.panels(_: ui.Service): { ui.Panel }
    local result = {}
    for _, panel in state.panels do
      if panel.live() then
        result[#result + 1] = panel.handle
      end
    end
    return table.freeze(result)
  end
  context:require(surfaces.capability):offer(context, {
    name = 'testing/ui-substitute',
    list = function()
      local result = {}
      for _, panel in state.panels do
        if panel.live() and panel.visible then
          result[#result + 1] = panel.surface
        end
      end
      return result
    end,
  })
  return service
end

substitute.definition = plugin.define {
  name = 'testing/ui-substitute',
  requires = substitute.requires,
  provides = { ui = ui.capability },
  init = function(context, _, provide)
    provide:provide(ui.capability, substitute.build(context))
  end,
}

return substitute

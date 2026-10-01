local plugin = require '@lunette-plugin'
local laser = require '@lunette-contracts/laser'
local panels = require '@lunette-contracts/panels'
local interaction = require '@lunette-contracts/interaction'
local provider: plugin.Definition<{}> = require '@lunette-plugins/laser'
local panelsProvider: plugin.Definition<{}> = require '@lunette-plugins/panels'
local interactionProvider: plugin.Definition<{}> = require '@lunette-plugins/interaction'

local consumer = plugin.define {
  name = 'consumer',
  requires = { panels = panels.capability, interaction = interaction.capability, laser = laser.capability },
  init = function(context: plugin.Context, _config: {}, _publish: plugin.Publisher)
    local panelService: panels.Service = context:require(panels.capability)
    local interactionService: interaction.Service = context:require(interaction.capability)
    local service: laser.Service = context:require(laser.capability)
    local targets: { laser.Laser } = service:attach(context, {
      readInput = function(_hand: laser.Hand): laser.Input?
        return nil
      end,
    })
    local surfaces: { laser.Surface } = {}
    for _, panel in ipairs(panelService:all()) do
      surfaces[#surfaces + 1] = panel
    end
    service:update(surfaces)
    local left: laser.Laser? = service:forHand 'left'
    if left then
      left:update {}
      left:vibrate()
      left:destroy()
    end
    local pointers: { interaction.Pointer } = interactionService:pointers()
    assert(#targets == 2 and #pointers >= 0)
  end,
}

return {
  provider = provider,
  panels = panelsProvider,
  interaction = interactionProvider,
  consumer = consumer,
}

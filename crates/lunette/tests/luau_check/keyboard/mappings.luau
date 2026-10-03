local plugin = require '@lunette-plugin'
local panels = require '@lunette-contracts/panels'
local interaction = require '@lunette-contracts/interaction'
local keyboard = require '@lunette-contracts/keyboard'
local panelsDefinition = require('@lunette-plugins/panels').definition
local interactionDefinition = require('@lunette-plugins/interaction').definition
local keyboardDefinition = require('@lunette-plugins/keyboard').definition

local consumer = plugin.define {
  name = 'consumer',
  requires = { panels = panels.capability, interaction = interaction.capability, keyboard = keyboard.capability },
  init = function(context: plugin.Context, _config: {}, _publish: plugin.Publisher)
    local panelService: panels.Service = context:require(panels.capability)
    local interactionService: interaction.Service = context:require(interaction.capability)
    local keyboardService: keyboard.Service = context:require(keyboard.capability)
    panelService:update()
    local pointers: { interaction.Pointer } = interactionService:pointers()
    local board: keyboard.Keyboard = keyboardService:new(context)
    assert(#pointers == 0 and not board.dead)
  end,
}

return {
  panels = panelsDefinition,
  interaction = interactionDefinition,
  keyboard = keyboardDefinition,
  consumer = consumer,
}

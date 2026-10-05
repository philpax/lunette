local plugin = require '@lunette-plugin'
local panels = require '@lunette-contracts/panels'
local interaction = require '@lunette-contracts/interaction'
local keyboard = require '@lunette-contracts/keyboard'
local keyboardProvider = require '@lunette-plugins/keyboard'
local panelProvider = require '@lunette-plugins/panels'
local pointerProvider = require '@lunette-plugins/interaction'
local provider: plugin.Definition<keyboardProvider.Config> = keyboardProvider.definition
local panelsProvider: plugin.Definition<panelProvider.Config> = panelProvider.definition
local interactionProvider: plugin.Definition<pointerProvider.Config> = pointerProvider.definition

local required: { read interaction: interaction.Capability, read panels: panels.Capability } = {
  interaction = interaction.capability,
  panels = panels.capability,
}
local provided: { read keyboard: keyboard.Capability } = { keyboard = keyboard.capability }

local consumer = plugin.define {
  name = 'consumer',
  requires = { keyboard = keyboard.capability },
  init = function(context: plugin.Context, _config: {}, _publish: plugin.Publisher)
    local service: keyboard.Service = context:require(keyboard.capability)
    local board: keyboard.Keyboard = service:new(context)
    assert(board:modifiers()[1] == nil)
  end,
}

return {
  provider = provider,
  panels = panelsProvider,
  interaction = interactionProvider,
  consumer = consumer,
  required = required,
  provided = provided,
}

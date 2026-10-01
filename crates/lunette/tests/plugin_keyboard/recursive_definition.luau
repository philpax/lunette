local plugin = require '@lunette-plugin'
local panels = require '@lunette-contracts/panels'
local interaction = require '@lunette-contracts/interaction'
local keyboard = require '@lunette-contracts/keyboard'
local provider: plugin.Definition<{}> = require('@lunette-plugins/keyboard').definition
local panelsProvider: plugin.Definition<{}> = require('@lunette-plugins/panels').definition
local interactionProvider: plugin.Definition<{}> = require('@lunette-plugins/interaction').definition

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
    local keys: { keyboard.Keyboard } = service:all()
    service:keyAt({}, 0, 0)
    assert(#keys == 0)
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

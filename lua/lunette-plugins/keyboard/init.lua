-- Reusable keyboard definition; resources are acquired during activation.
local plugin = require '@lunette-plugin'
local interaction = require '@lunette-contracts/interaction'
local keyboard = require '@lunette-contracts/keyboard'
local service = require '@lunette-plugins/keyboard/service'

local required = {
  interaction = interaction.capability,
}
local provided = { keyboard = keyboard.capability }

return plugin.define {
  name = 'keyboard',
  requires = required,
  provides = provided,
  init = function(context: plugin.Context, config: {}, publish: plugin.Publisher)
    service.initialize(context, config, publish)
  end,
}

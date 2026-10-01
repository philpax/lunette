-- Declares the scoped adoption provider.
local plugin = require '@lunette-plugin'
local adoption = require '@lunette-contracts/adoption'
local panels = require '@lunette-contracts/panels'
local rules = require '@lunette-contracts/rules'
local create = require '@lunette-plugins/adoption/service'

local required: plugin.Declaration = {
  panels = panels.capability,
  rules = rules.capability,
}
local provided: plugin.Declaration = { adoption = adoption.capability }

return plugin.define {
  name = 'adoption',
  requires = required,
  provides = provided,
  init = function(context: plugin.Context, _config: {}, provide: plugin.Publisher)
    provide:provide(adoption.capability, create(context))
  end,
}

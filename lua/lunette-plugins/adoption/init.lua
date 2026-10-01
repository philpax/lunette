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

return plugin.define(
  function(config: {}): {}
    return config
  end,
  required,
  provided,
  function(context, _config, provide)
    provide:provide(adoption.capability, create(context))
  end
)

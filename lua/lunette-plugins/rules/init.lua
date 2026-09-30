-- Declares window placement policy and its resource dependencies.
local plugin = require '@lunette-plugin'
local rules = require '@lunette-contracts/rules'
local tags = require '@lunette-contracts/tags'
local panels = require '@lunette-contracts/panels'
local create = require '@lunette-plugins/rules/service'
local required: plugin.Declaration = {
  panels = panels.capability,
  tags = tags.capability,
}
local provided: plugin.Declaration = { rules = rules.capability }
return plugin.define(
  function(config: {}): {}
    return config
  end,
  required,
  provided,
  function(context, _config, provide)
    provide:provide(rules.capability, create(context))
  end
)

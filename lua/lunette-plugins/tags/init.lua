-- Declares the tags provider and its panels dependency.
local plugin = require '@lunette-plugin'
local tags = require '@lunette-contracts/tags'
local panels = require '@lunette-contracts/panels'
local create = require '@lunette-plugins/tags/service'
local required: plugin.Declaration = { panels = panels.capability }
local provided: plugin.Declaration = { tags = tags.capability }
return plugin.define(
  function(config: {}): {}
    return config
  end,
  required,
  provided,
  function(context, _config, provide)
    provide:provide(tags.capability, create(context))
  end
)

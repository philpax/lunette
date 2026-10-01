-- Declares the tags provider. Membership borrows panels without requiring the
-- panels contract.
local plugin = require '@lunette-plugin'
local tags = require '@lunette-contracts/tags'
local create = require '@lunette-plugins/tags/service'
local required: plugin.Declaration = {}
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

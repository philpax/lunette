-- Declares the tags provider. Membership borrows panels without requiring the
-- panels contract.
local plugin = require '@lunette-plugin'
local tags = require '@lunette-contracts/tags'
local create = require '@lunette-plugins/tags/service'
local required: plugin.Declaration = {}
local provided: plugin.Declaration = { tags = tags.capability }
return plugin.define {
  name = 'tags',
  requires = required,
  provides = provided,
  init = function(context: plugin.Context, _config: {}, provide: plugin.Publisher)
    provide:provide(tags.capability, create(context))
  end,
}

-- Declares arc layout policy over the tags service.
local plugin = require '@lunette-plugin'
local layout = require '@lunette-contracts/layout'
local tags = require '@lunette-contracts/tags'
local create = require '@lunette-plugins/layout/arc/service'
local required: plugin.Declaration = { tags = tags.capability }
local provided: plugin.Declaration = { arc = layout.arc }
return plugin.define {
  name = 'layout/arc',
  requires = required,
  provides = provided,
  init = function(context: plugin.Context, _config: {}, provide: plugin.Publisher)
    provide:provide(layout.arc, create(context))
  end,
}

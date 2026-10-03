-- The desktop's workspace tag, held and selected while active. It is held rather than made, so the entries
-- may start in any order.
local plugin = require '@lunette-plugin'
local tags = require '@lunette-contracts/tags'

-- What a configuration gives: every option optional.
export type Config = {
  read name: string?,
}

export type Settings = {
  read name: string,
}

local DEFAULTS: Settings = { name = 'main' }

local required: plugin.Declaration = { tags = tags.capability }

return plugin.define {
  name = 'desktop/workspace',
  requires = required,
  init = function(context: plugin.Context, config: Config, _publish: plugin.Publisher): ()
    local settings: Settings = plugin.options { name = 'desktop/workspace', defaults = DEFAULTS, config = config }
    if settings.name == '' then
      error('plugin desktop/workspace: option name is a non-empty tag name', 0)
    end
    local service: tags.Service = context:require(tags.capability)
    local tag = service:hold(context, { name = settings.name, selected = true })
    tag:setSelected(context, { selected = true })
  end,
}

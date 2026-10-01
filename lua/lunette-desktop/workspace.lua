-- The desktop's workspace tag.
--
-- `name` is the tag this consumer creates, selected, and holds for as long as
-- it is active. Adopted windows join it through `desktop/adoption`'s `tags`
-- and `desktop/arrange` arranges its members, so the three name the same tag.
-- A tag of that name held by another owner raises as the consumer activates,
-- rather than being borrowed without a say in its lifetime.
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
    service:new(context, settings.name, { selected = true })
  end,
}

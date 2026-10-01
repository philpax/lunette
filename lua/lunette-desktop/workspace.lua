-- The desktop's workspace tag.
--
-- `name` is the tag this consumer holds, and selects, for as long as it is
-- active. Adopted windows join it through `desktop/adoption`'s `tags`, and
-- `desktop/arrange` arranges it with the other tags. The tag is held rather
-- than made, so whichever of this consumer, a placement, or the saved
-- arrangement needs it first makes it, and it lasts while any of them holds
-- it: the order the entries start in does not matter.
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

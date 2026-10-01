-- Adoption of the session's windows into the desktop.
--
-- The consumer installs the adoption provider's native pose source and then
-- starts adoption, so every window, open now or later, becomes a panel placed
-- by the rules. `tags` are the tags an adopted window joins unless a rule
-- names others; the default is the workspace tag. Other consumers hear each
-- placement through the adoption contract's `onPlaced`, and `desktop/arrange`
-- arranges the windows placed without a pose.
local plugin = require '@lunette-plugin'
local adoption = require '@lunette-contracts/adoption'

-- What a configuration gives: every option optional.
export type Config = {
  read tags: { string }?,
}

export type Settings = {
  read tags: { string },
}

local DEFAULTS: Settings = { tags = { 'main' } }

local required: plugin.Declaration = { adoption = adoption.capability }

return plugin.define {
  name = 'desktop/adoption',
  requires = required,
  init = function(context: plugin.Context, config: Config, _publish: plugin.Publisher): ()
    local settings: Settings = plugin.options { name = 'desktop/adoption', defaults = DEFAULTS, config = config }
    for index, tag in ipairs(settings.tags) do
      if type(tag) ~= 'string' or tag == '' then
        error(string.format('plugin desktop/adoption: option tags[%d] is a non-empty tag name', index), 0)
      end
    end
    local service: adoption.Service = context:require(adoption.capability)
    service:install(context)
    service:start(context, { defaults = { tags = settings.tags } })
  end,
}

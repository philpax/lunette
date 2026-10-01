-- Adoption of the session's windows into the desktop.
--
-- The consumer installs the adoption provider's native pose source and then
-- starts adoption, so every window, open now or later, becomes a panel placed
-- by lunette/placement. `tags` are the tags an adopted window joins unless a
-- rule names others; the default is the workspace tag. `filter` answers
-- whether to adopt a window, and a window a rule gives `adopt = false` is
-- not adopted either, so a plugin that draws a window itself can keep it.
-- Other consumers hear each placement through the placement contract's
-- `onPlaced`, and `desktop/arrange` arranges the windows placed without a
-- pose.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local adoption = require '@lunette-contracts/adoption'

-- What a configuration gives: every option optional.
export type Config = {
  read tags: { string }?,
  read filter: ((lunette.Window) -> boolean)?,
}

export type Settings = {
  read tags: { string },
  read filter: (lunette.Window) -> boolean,
}

local function adoptEvery(_window: lunette.Window): boolean
  return true
end

local DEFAULTS: Settings = { tags = { 'main' }, filter = adoptEvery }

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
    service:start(context, { defaults = { tags = settings.tags }, filter = settings.filter })
  end,
}

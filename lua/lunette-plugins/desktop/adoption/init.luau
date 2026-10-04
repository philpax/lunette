-- Installs native pose restoration and adopts eligible windows as panels with configured default tags.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local adoption = require '@lunette-contracts/adoption'

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

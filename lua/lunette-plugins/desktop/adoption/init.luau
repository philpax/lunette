-- Adopts eligible windows as panels with configured default tags, and remembers their hand-placed poses.
local plugin = require '@lunette-plugin'
local adoption = require '@lunette-contracts/adoption'
local config = require '@lunette-plugins/desktop/adoption/config'
local poseMemory = require '@lunette-plugins/desktop/adoption/pose-memory'

export type Config = config.Config
export type Settings = config.Settings

local required: plugin.Declaration = { adoption.capability }

return plugin.consumer<<Config, Settings>> {
  name = 'desktop/adoption',
  requires = required,
  schema = config.schema,
  init = function(context: plugin.Context, settings: Settings): ()
    local service: adoption.Service = context:require(adoption.capability)
    -- Pose memory is a child, so a drops or panels outage leaves adoption running. Its rule source registers before
    -- the start resolves the first window.
    context:child(poseMemory, { precedence = settings.precedence })
    service:start(context, { defaults = { tags = settings.tags }, filter = settings.filter })
  end,
}

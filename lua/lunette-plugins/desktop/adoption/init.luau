-- Installs native pose restoration, adopts eligible windows as panels with configured default tags, and writes a dropped window's pose to the property restoration reads.
local plugin = require '@lunette-plugin'
local adoption = require '@lunette-contracts/adoption'
local drops = require '@lunette-contracts/drops'
local panels = require '@lunette-contracts/panels'
local vocabulary = require '@lunette-contracts/vocabulary'
local config = require '@lunette-plugins/desktop/adoption/config'

export type Config = config.Config
export type Settings = config.Settings

-- Pose memory is a child, so a drops or panels outage leaves adoption running.
local poseMemory = plugin.consumer<<{}, {}>>({
  name = 'desktop/adoption/pose-memory',
  requires = { drops.capability, panels.capability },
  init = function(context: plugin.Context, _settings: {}): ()
    local dropService: drops.Service = context:require(drops.capability)
    local panelService: panels.Service = context:require(panels.capability)
    dropService:onDropped(context, {
      run = function(drop: drops.Drop): ()
        local dropped = drop.surface
        if dropped.dead or dropped.kind ~= 'window' or dropped.source.dead then
          return
        end
        local window = dropped.source
        local panel = panelService:forSource(window)
        local pose = if panel and not panel.dead then panel.pose else dropped.pose
        if pose then
          window:setProperty(vocabulary.POSE_PROPERTY, vocabulary.encodePose(pose))
        end
      end,
    })
  end,
}).definition

local required: plugin.Declaration = { adoption.capability }

return plugin.consumer<<Config, Settings>>({
  name = 'desktop/adoption',
  requires = required,
  schema = config.schema,
  init = function(context: plugin.Context, settings: Settings): ()
    local service: adoption.Service = context:require(adoption.capability)
    service:install(context)
    service:start(context, { defaults = { tags = settings.tags }, filter = settings.filter })
    context:child(poseMemory)
  end,
}).definition

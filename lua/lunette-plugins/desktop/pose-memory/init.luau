-- The window property persists dropped poses across Lua state reloads.
local plugin = require '@lunette-plugin'
local drops = require '@lunette-contracts/drops'
local panels = require '@lunette-contracts/panels'
local vocabulary = require '@lunette-contracts/vocabulary'

export type Config = {}
export type Settings = {}

local required: plugin.Declaration = {
  drops = drops.capability,
  panels = panels.capability,
}

return plugin.consumer<<Config, Settings>>({
  name = 'desktop/pose-memory',
  requires = required,
  init = function(context: plugin.Context, _settings: Settings): ()
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

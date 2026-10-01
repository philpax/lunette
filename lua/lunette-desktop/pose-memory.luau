-- The pose a dropped window was left at, kept on the window's `lunette.pose` property. The property outlives
-- the Lua state, so the adoption provider's native source restores the place across a source reload.
local plugin = require '@lunette-plugin'
local drops = require '@lunette-contracts/drops'
local panels = require '@lunette-contracts/panels'
local vocabulary = require '@lunette-contracts/vocabulary'

local required: plugin.Declaration = {
  drops = drops.capability,
  panels = panels.capability,
}

return plugin.define {
  name = 'desktop/pose-memory',
  requires = required,
  init = function(context: plugin.Context, config: {}, _publish: plugin.Publisher): ()
    -- The consumer takes no options, so any option is a mistake worth naming.
    plugin.options { name = 'desktop/pose-memory', defaults = {}, config = config }
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
}

-- Remembers a hand-placed window pose across Lua state reloads: a drop writes it to the window, and a rule source
-- reads it back when the window is placed again.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local drops = require '@lunette-contracts/drops'
local panels = require '@lunette-contracts/panels'
local rules = require '@lunette-contracts/rules'
local vocabulary = require '@lunette-contracts/vocabulary'

local function keptPose(window: lunette.Window): rules.Properties?
  local kept = window:getProperty(vocabulary.POSE_PROPERTY)
  if type(kept) ~= 'string' then
    return nil
  end
  return { pose = kept }
end

return plugin.consumer<<{}, {}>>({
  name = 'desktop/adoption/pose-memory',
  requires = { rules.capability, drops.capability, panels.capability },
  init = function(context: plugin.Context, _settings: {}): ()
    local ruleService: rules.Service = context:require(rules.capability)
    local dropService: drops.Service = context:require(drops.capability)
    local panelService: panels.Service = context:require(panels.capability)
    ruleService:addSource(
      context,
      { name = 'lunette.pose', precedence = vocabulary.PRECEDENCE.native, resolve = keptPose }
    )
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

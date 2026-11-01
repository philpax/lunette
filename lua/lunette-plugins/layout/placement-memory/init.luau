-- Remembers where the user leaves each surface that declares a placement key: a drop saves its pose and size, and a
-- surface that has its key the first time it is offered in an activation returns there. A surface that gains a key
-- later is saved when dropped but not moved, so an owner can key a panel as the user tears it off.
local plugin = require '@lunette-plugin'
local drops = require '@lunette-contracts/drops'
local frame = require '@lunette-contracts/frame'
local surfaces = require '@lunette-contracts/surfaces'
local vocabulary = require '@lunette-contracts/vocabulary'
local config = require '@self/config'
local memory = require '@self/private/memory'

export type Config = config.Config
export type Settings = config.Settings

return plugin.consumer<<Config, Settings>> {
  name = 'desktop/placement-memory',
  schema = config.schema,
  requires = { drops.capability, frame.capability, surfaces.capability },
  init = function(context: plugin.Context, settings: Settings): ()
    local dropService: drops.Service = context:require(drops.capability)
    local frameService: frame.Service = context:require(frame.capability)
    local surfaceService: surfaces.Service = context:require(surfaces.capability)
    local placed = table.clone(settings.placed) :: { [string]: config.Placement }
    -- Surfaces already offered in this activation, so later frames leave them where they are.
    local seen: { [vocabulary.Surface]: true } = setmetatable({}, { __mode = 'k' }) :: any
    dropService:onDropped(context, {
      run = function(drop: drops.Drop): ()
        local surface = drop.surface
        local key = surface.placementKey
        if not key or surface.dead or not context:active() then
          return
        end
        local placement = memory.capture(surface)
        if placement then
          placed[key] = placement
          context:save { placed = table.clone(placed) }
        end
      end,
    })
    -- Surfaces are offered before this update, and the frame draws after it, so a restored surface never shows at its
    -- owner's pose first.
    frameService:onUpdate(context, {
      phase = 'scene',
      order = 0,
      run = function(_dt: number): ()
        for _, surface in surfaceService:all() do
          if not seen[surface] and not surface.dead then
            seen[surface] = true
            local key = surface.placementKey
            local placement = if key then placed[key] else nil
            if placement then
              memory.apply(surface, placement)
            end
          end
        end
      end,
    })
  end,
}

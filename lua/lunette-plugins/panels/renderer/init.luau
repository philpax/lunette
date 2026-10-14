-- Renders panels independently of the surface-offering child plugin.
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local panels = require '@lunette-contracts/panels'
local surfaces = require '@lunette-contracts/surfaces'

export type Config = {}
export type Settings = {}

local offering = plugin.consumer<<Config, Settings>>({
  name = 'desktop/render/surfaces',
  requires = { panels.capability, surfaces.capability },
  init = function(context: plugin.Context, _settings: Settings): ()
    local panelService: panels.Service = context:require(panels.capability)
    local surfaceService: surfaces.Service = context:require(surfaces.capability)
    surfaceService:offer(context, {
      name = 'desktop/panels',
      list = function(): { surfaces.Surface }
        local result: { surfaces.Surface } = {}
        for _, item in ipairs(panelService:all()) do
          if not item.dead and not item.hidden then
            result[#result + 1] = item
          end
        end
        return result
      end,
    })
  end,
}).definition

local required: plugin.Declaration = {
  frame.capability,
  panels.capability,
}

return plugin.consumer<<Config, Settings>> {
  name = 'desktop/render',
  requires = required,
  init = function(context: plugin.Context, _settings: Settings): ()
    local frameService: frame.Service = context:require(frame.capability)
    local panelService: panels.Service = context:require(panels.capability)
    context:child(offering)
    frameService:onUpdate(context, {
      phase = 'scene',
      run = function(_dt: number)
        panelService:update()
      end,
    })
    frameService:onDraw(context, {
      phase = 'scene',
      run = function(pass: Pass)
        panelService:draw(pass)
      end,
    })
  end,
}

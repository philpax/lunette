-- Renders panels independently of the surface-offering child plugin.
local plugin = require '@lunette-plugin'
local schema = require '@lunette-plugin/schema'
local frame = require '@lunette-contracts/frame'
local panels = require '@lunette-contracts/panels'
local surfaces = require '@lunette-contracts/surfaces'

local descriptor = schema.object {}
export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

local offering = plugin.consumer<<Config, Settings>>({
  name = 'desktop/render/surfaces',
  requires = { panels = panels.capability, surfaces = surfaces.capability },
  schema = descriptor,
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
  frame = frame.capability,
  panels = panels.capability,
}

return plugin.consumer<<Config, Settings>>({
  name = 'desktop/render',
  requires = required,
  schema = descriptor,
  init = function(context: plugin.Context, _settings: Settings): ()
    local frameService: frame.Service = context:require(frame.capability)
    local panelService: panels.Service = context:require(panels.capability)
    context:child(offering, {})
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
}).definition

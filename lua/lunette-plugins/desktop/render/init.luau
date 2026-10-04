-- Renders panels independently of the surface-offering child plugin.
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local panels = require '@lunette-contracts/panels'
local surfaces = require '@lunette-contracts/surfaces'

local offering = plugin.define {
  name = 'desktop/render/surfaces',
  requires = { panels = panels.capability, surfaces = surfaces.capability },
  init = function(context: plugin.Context, _config: {}, _publish: plugin.Publisher): ()
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
}

local required: plugin.Declaration = {
  frame = frame.capability,
  panels = panels.capability,
}

return plugin.define {
  name = 'desktop/render',
  requires = required,
  init = function(context: plugin.Context, config: {}, _publish: plugin.Publisher): ()
    plugin.options { name = 'desktop/render', defaults = {}, config = config }
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
}

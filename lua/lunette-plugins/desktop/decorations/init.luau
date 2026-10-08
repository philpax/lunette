-- Offers draggable title bars that stand in for their panels during drops. Hidden panels and panels with chrome are not decorated.
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local panels = require '@lunette-contracts/panels'
local quad = require '@lunette-contracts/quad'
local surface = require '@lunette-contracts/surface'
local surfaces = require '@lunette-contracts/surfaces'

local config = require '@lunette-plugins/desktop/decorations/config'
local controls = require '@lunette-plugins/desktop/decorations/controls'
local passState = require '@lunette-plugins/pass-state'

export type Color = config.Color
export type Style = config.Style
export type Config = config.Config
export type Settings = config.Settings

local required: plugin.Declaration = {
  frame = frame.capability,
  panels = panels.capability,
  surfaces = surfaces.capability,
}

type Decoration = {
  read panel: panels.Panel,
  read bar: surface.Surface,
  read pose: Mat4,
  highlighted: boolean,
}

local function setColor(pass: Pass, color: Color): ()
  pass:setColor(color[1], color[2], color[3], color[4])
end

local function decorated(panel: panels.Panel): boolean
  return not panel.dead and not panel.hidden and not panel.chrome
end

return plugin.consumer<<Config, Settings>>({
  name = 'desktop/decorations',
  requires = required,
  schema = config.schema,
  init = function(context: plugin.Context, settings: Settings): ()
    local style = settings.style
    local frameService: frame.Service = context:require(frame.capability)
    local panelService: panels.Service = context:require(panels.capability)
    local surfaceService: surfaces.Service = context:require(surfaces.capability)
    local decorations: { [panels.Panel]: Decoration } = {}
    local order: { Decoration } = {}

    -- How far above the panel's centre the bar's centre is.
    local function offsetOf(panel: panels.Panel): number
      return panel.height / 2 + style.margin + style.barHeight / 2
    end
    local function placeBar(decoration: Decoration): ()
      local panel = decoration.panel
      decoration.pose:set(panel.pose):translate(0, offsetOf(panel), 0)
    end

    local function decorate(given: panels.Panel): ()
      if given.dead or decorations[given] then
        return
      end
      local panel: panels.Panel = given
      local decoration: Decoration
      local function raycast(
        _self: surface.Surface,
        origin: vector,
        direction: vector,
        backFace: boolean?
      ): (number?, number?, number?)
        if not decorated(panel) then
          return nil, nil, nil
        end
        placeBar(decoration)
        local x, y, distance = quad.hit({
          pose = decoration.pose,
          width = panel.width,
          height = style.barHeight,
          pixelWidth = 1,
          pixelHeight = 1,
          backFace = backFace,
        }, origin, direction)
        if x and x >= 1 - controls.layout(panel, style).width / panel.width then
          return nil, nil, nil
        end
        return x, y, distance
      end
      local function setPose(_self: surface.Surface, pose: Mat4): ()
        if panel.dead then
          return
        end
        panel:setPose(lovr.math.newMat4(pose):translate(0, -offsetOf(panel), 0))
        placeBar(decoration)
      end
      local function setHighlighted(_self: surface.Surface, value: boolean): ()
        decoration.highlighted = value
      end
      local pose = lovr.math.newMat4()
      local bar: surface.Surface
      if panel.kind == 'window' then
        local windowBar: surface.Surface = {
          kind = 'window' :: 'window',
          source = panel.source,
          dead = false,
          grabbable = true,
          triggerGrabbable = true,
          pose = pose,
          height = style.barHeight,
          raycast = raycast,
          setPose = setPose,
          setHighlighted = setHighlighted,
        }
        bar = windowBar
      else
        local monitorBar: surface.Surface = {
          kind = 'monitor' :: 'monitor',
          source = panel.source,
          dead = false,
          grabbable = true,
          triggerGrabbable = true,
          pose = pose,
          height = style.barHeight,
          raycast = raycast,
          setPose = setPose,
          setHighlighted = setHighlighted,
        }
        bar = monitorBar
      end
      decoration = { panel = panel, bar = bar, pose = pose, highlighted = false }
      placeBar(decoration)
      decorations[panel] = decoration
      order[#order + 1] = decoration
    end

    local function forget(panel: panels.Panel): ()
      local decoration = decorations[panel]
      if not decoration then
        return
      end
      decorations[panel] = nil
      local index = table.find(order, decoration)
      if index then
        table.remove(order, index)
      end
      (decoration.bar :: any).dead = true
    end

    panelService:onAdded(context, decorate)
    panelService:onRemoved(context, { run = forget })
    for _, panel in ipairs(panelService:all()) do
      decorate(panel)
    end

    surfaceService:offer(context, {
      name = 'desktop/decorations',
      list = function(): { surface.Surface }
        local result: { surface.Surface } = {}
        for _, decoration in ipairs(order) do
          if decorated(decoration.panel) then
            placeBar(decoration)
            result[#result + 1] = decoration.bar
          end
        end
        return result
      end,
    })

    context:child(controls.definition(style), {})
    frameService:onDraw(context, {
      phase = 'scene',
      run = function(pass: Pass)
        for _, decoration in ipairs(order) do
          local panel = decoration.panel
          if decorated(panel) then
            placeBar(decoration)
            local lit = panel.highlighted or decoration.highlighted
            setColor(pass, if lit then style.borderHighlightColor else style.borderColor)
            pass:plane(
              lovr.math
                .mat4(panel.pose)
                :translate(0, 0, -style.borderDepth)
                :scale(panel.width + style.borderThickness * 2, panel.height + style.borderThickness * 2, 1),
              'fill',
              1,
              1
            )
            setColor(pass, if decoration.highlighted then style.barHighlightColor else style.barColor)
            pass:plane(lovr.math.mat4(decoration.pose):scale(panel.width, style.barHeight, 1), 'fill', 1, 1)
            local title = if panel.kind == 'window'
              then panel.title or panel.source.title
              else panel.title or panel.source.name
            if title then
              local reserved = controls.layout(panel, style).width
              local available = panel.width - reserved
              passState.withRestore(pass, function()
                pass:setShader()
                pass:setMaterial(nil)
                pass:setFont(lovr.graphics.getDefaultFont())
                pass:setDepthTest()
                pass:setDepthWrite(false)
                setColor(pass, style.titleColor)
                pass:text(
                  title,
                  lovr.math
                    .mat4(decoration.pose)
                    :translate(-reserved / 2, 0, 0.001)
                    :scale(vector.pack(style.titleHeight)),
                  available / style.titleHeight,
                  'center',
                  'middle'
                )
              end)
            end
          end
        end
        pass:setColor(1, 1, 1, 1)
      end,
    })
  end,
}).definition

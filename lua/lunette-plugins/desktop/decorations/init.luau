-- Offers draggable title bars that stand in for their panels during drops. Hidden panels and panels with chrome are not decorated.
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local panels = require '@lunette-contracts/panels'
local quad = require '@lunette-contracts/quad'
local surface = require '@lunette-contracts/surface'
local surfaces = require '@lunette-contracts/surfaces'

export type Color = { number }

export type Style = {
  read barHeight: number,
  read margin: number,
  read barColor: Color,
  read barHighlightColor: Color,
  read borderThickness: number,
  read borderDepth: number,
  read borderColor: Color,
  read borderHighlightColor: Color,
  read titleHeight: number,
  read titleColor: Color,
}

export type Config = {
  read style: {
    read barHeight: number?,
    read margin: number?,
    read barColor: Color?,
    read barHighlightColor: Color?,
    read borderThickness: number?,
    read borderDepth: number?,
    read borderColor: Color?,
    read borderHighlightColor: Color?,
    read titleHeight: number?,
    read titleColor: Color?,
  }?,
}

export type Settings = {
  read style: Style,
}

local DEFAULTS: Settings = {
  style = {
    barHeight = 0.05,
    margin = 0.01,
    barColor = { 0.14, 0.14, 0.17, 0.95 },
    barHighlightColor = { 0.35, 0.55, 0.95, 0.95 },
    borderThickness = 0.008,
    borderDepth = 0.001,
    borderColor = { 0.14, 0.14, 0.17, 0.95 },
    borderHighlightColor = { 0.35, 0.55, 0.95, 0.95 },
    titleHeight = 0.025,
    titleColor = { 1, 1, 1, 1 },
  },
}

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

local function resolve(config: unknown): Settings
  local settings: Settings = plugin.options { name = 'desktop/decorations', defaults = DEFAULTS, config = config }
  local style = settings.style
  for _, name in ipairs { 'barHeight', 'titleHeight' } do
    local value = (style :: any)[name] :: number
    if not (value > 0) then
      error('plugin desktop/decorations: option style.' .. name .. ' is a positive number, not ' .. value, 0)
    end
  end
  return settings
end

local function setColor(pass: Pass, color: Color): ()
  pass:setColor(color[1], color[2], color[3], color[4])
end

local function decorated(panel: panels.Panel): boolean
  return not panel.dead and not panel.hidden and not panel.chrome
end

return plugin.define {
  name = 'desktop/decorations',
  requires = required,
  init = function(context: plugin.Context, config: Config, _publish: plugin.Publisher): ()
    local style = resolve(config).style
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
        return quad.hit({
          pose = decoration.pose,
          width = panel.width,
          height = style.barHeight,
          pixelWidth = 1,
          pixelHeight = 1,
          backFace = backFace,
        }, origin, direction)
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
              setColor(pass, style.titleColor)
              pass:text(
                title,
                lovr.math.mat4(decoration.pose):translate(0, 0, 0.001):scale(vector.pack(style.titleHeight)),
                0,
                'center',
                'middle'
              )
            end
          end
        end
        pass:setColor(1, 1, 1, 1)
      end,
    })
  end,
}

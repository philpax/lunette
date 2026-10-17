-- Registers the control panel's two views as kinds whose visuals draw volumes: the band skyline, a field of columns
-- with a short history, and the sky model, the backdrop's own sky and curtains in miniature with the facing, the
-- onset anchor, and the live onsets marked on its ground. Each volume reads the view's sources when it draws, so the
-- views move every frame without the panel recording them again.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local uiHost = require '@lunette-contracts/ui-host'
local model = require '../rendering/model'
local scene = require './scene'

local kinds = {}

export type Constructors = { read Skyline: uiHost.Constructor, read Model: uiHost.Constructor }

-- What the views draw from. The backdrop updates `observed` each frame and the panel samples `history`.
export type Sources = {
  read observed: scene.Observed,
  read history: { scene.Row },
  read palette: scene.Palette,
  -- Draws the backdrop as a model of a radius about the pass's origin, at an opacity.
  read miniature: (Pass, model.Frame, number, number?, number) -> (),
  read sectors: number,
  read hold: number,
}

-- Metres the skyline's history reaches out of the panel.
local SKYLINE_DEPTH = 0.05
-- How far the curtains reach past the sky's distance as they meander and fold, so the model fits its volume.
local CURTAIN_REACH = 1.4
-- A light from above and to the left of the viewer shades the faces of the columns and markers.
local VERTEX = [[
  vec4 lovrmain() {
    return DefaultPosition;
  }
]]
local SHADED = [[
  vec4 lovrmain() {
    float shade = .55 + .45 * max(dot(normalize(Normal), normalize(vec3(-.4, .7, .6))), 0.);
    return vec4(Color.rgb * shade, Color.a);
  }
]]

local shaded: (plugin.Context) -> () -> Shader
local tint: (Pass, scene.Color, uiHost.Volume) -> ()

function kinds.register(host: uiHost.Service, owner: plugin.Context, sources: Sources): Constructors
  local shader = shaded(owner)
  local skyline = host:registerKind(owner, {
    name = 'desktop/backdrop/skyline',
    layout = {
      kind = 'leaf',
      style = function(props: uiHost.Props): lunette.LayoutStyle
        return { height = props.height, grow = 1, alignSelf = 'stretch' }
      end,
    },
    visuals = { 'desktop/backdrop/skyline' },
  })
  host:registerVisual(owner, 'desktop/backdrop/skyline', function(node: uiHost.Node, draw: uiHost.Draw): ()
    local theme = node.theme
    draw:box(nil, { fill = theme.colors.sunken, radius = theme.radii.control })
    draw:volume(nil, {
      depth = SKYLINE_DEPTH,
      draw = function(pass: Pass, volume: uiHost.Volume): ()
        local shape = scene.skyline(
          sources.history,
          sources.observed.raw,
          sources.palette,
          volume.width * 0.94,
          volume.height * 0.9,
          volume.depth
        )
        pass:setShader(shader())
        pass:setDepthTest 'gequal'
        pass:setDepthWrite(true)
        -- Older rows are nearer the panel and more transparent, so they draw first.
        for index = #shape.bars, 1, -1 do
          local bar = shape.bars[index]
          tint(pass, bar.color, volume)
          pass:box(bar.x, bar.y, bar.z, bar.width, bar.height, bar.depth)
        end
        for _, cap in shape.caps do
          tint(pass, cap.color, volume)
          pass:box(cap.x, cap.y, cap.z, cap.width, cap.height, cap.depth)
        end
      end,
    })
  end)
  local skyModel = host:registerKind(owner, {
    name = 'desktop/backdrop/model',
    layout = {
      kind = 'leaf',
      style = function(props: uiHost.Props): lunette.LayoutStyle
        return { width = props.size, height = props.size }
      end,
    },
    visuals = { 'desktop/backdrop/model' },
  })
  host:registerVisual(owner, 'desktop/backdrop/model', function(node: uiHost.Node, draw: uiHost.Draw): ()
    local theme = node.theme
    local size = node.props.size :: number
    local accent = table.clone(theme.colors.accent :: { number })
    draw:box(nil, { fill = theme.colors.sunken, radius = theme.radii.control })
    draw:volume(nil, {
      depth = size,
      draw = function(pass: Pass, volume: uiHost.Volume): ()
        local radius = math.min(volume.width, volume.height, volume.depth) / 2 / CURTAIN_REACH
        local observed = sources.observed
        local markers = scene.markers(observed, sources.palette, sources.sectors, sources.hold, accent)
        -- The model sits in the middle of the volume and turns with the world rather than the panel, so each of its
        -- directions is the direction in the sky it shows.
        pass:translate(0, 0, volume.depth / 2)
        local angle, ax, ay, az = volume.pose:getOrientation()
        pass:rotate(-angle, ax, ay, az)
        pass:setShader(shader())
        pass:setDepthTest 'gequal'
        pass:setDepthWrite(true)
        tint(pass, { 0.16, 0.18, 0.22, 0.9 }, volume)
        pass:cylinder(vector.create(0, -radius * 0.04, 0), vector.create(0, -radius * 0.015, 0), radius * 1.06, true)
        for _, rod in markers.rods do
          tint(pass, rod.color, volume)
          pass:capsule(rod.from * radius, rod.to * radius, rod.radius * radius)
        end
        for _, ball in markers.balls do
          tint(pass, ball.color, volume)
          local at = ball.at * radius
          pass:sphere(at.x, at.y, at.z, ball.radius * radius)
        end
        sources.miniature(pass, observed.frame, radius, observed.facing, volume.opacity * (1 - volume.scrim))
      end,
    })
  end)
  return table.freeze { Skyline = skyline, Model = skyModel }
end

-- The shader, compiled when a view first draws and released with the owner.
shaded = function(owner: plugin.Context): () -> Shader
  local held: Shader? = nil
  return function(): Shader
    if held then
      return held
    end
    local made: Shader? = nil
    owner:effect(function(): () -> ()
      local compiled = lovr.graphics.newShader(VERTEX, SHADED, { label = 'desktop/backdrop/views' })
      made = compiled
      return function(): ()
        compiled:release()
      end
    end)
    held = made
    return assert(made, 'backdrop: the view shader did not compile')
  end
end

tint = function(pass: Pass, color: scene.Color, volume: uiHost.Volume): ()
  local keep = 1 - volume.scrim
  pass:setColor(color[1] * keep, color[2] * keep, color[3] * keep, (color[4] or 1) * volume.opacity)
end

return kinds

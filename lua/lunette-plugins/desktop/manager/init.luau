-- Provides a movable projected surface for inspecting and changing the session composition.

local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local surfaces = require '@lunette-contracts/surfaces'
local surface = require '@lunette-contracts/surface'
local composition = require '@lunette-contracts/composition'
local quad = require '@lunette-contracts/quad'
local config = require '@lunette-plugins/desktop/manager/config'
local controller = require '@lunette-plugins/desktop/manager/controller'
local brokers = require '@lunette-plugins/desktop/manager/brokers'
local draw = require '@lunette-plugins/desktop/manager/draw'

export type Config = config.Config
export type Settings = config.Settings

return plugin.consumer<<Config, Settings>>({
  name = 'desktop/manager',
  schema = config.schema,
  requires = {
    composition = composition.capability,
    frame = frame.capability,
    surfaces = surfaces.capability,
  },
  init = function(context: plugin.Context, settings: Settings): ()
    local compositionService = context:require(composition.capability)
    local frameService = context:require(frame.capability)
    local surfaceService = context:require(surfaces.capability)
    local pixels = settings.pixels
    local pixelHeight = pixels * settings.height / settings.width
    local visible = settings.visible
    local dead = false
    local pose = lovr.math.newMat4():translate(settings.position)
    local state = controller.new(
      compositionService,
      brokers.watch(context),
      pixels,
      pixelHeight,
      function(records, sidebar): { string }
        return draw.wrapDetails(lovr.graphics.getDefaultFont(), records, sidebar)
      end
    )
    local hovered: surface.Pointer? = nil
    local captured: surface.Pointer? = nil
    local point = { x = 0, y = 0 }
    local function cancelInput(): ()
      hovered, captured = nil, nil
      point = { x = 0, y = 0 }
      controller.cancel(state)
    end
    local offered = {
      kind = nil,
      dead = false,
      grabbable = true,
      pose = pose,
      width = settings.width,
      height = settings.height,
      raycast = function(_self: surface.Surface, origin: vector, direction: vector): (number?, number?, number?)
        if dead or not visible then
          return nil, nil, nil
        end
        return quad.hit({
          pose = pose,
          width = settings.width,
          height = settings.height,
          pixelWidth = pixels,
          pixelHeight = pixelHeight,
        }, origin, direction)
      end,
      setPose = function(_self: surface.Surface, nextPose: Mat4): ()
        if not dead then
          pose:set(nextPose)
        end
      end,
      onHover = function(_self: surface.Surface, x: number?, y: number?, pointer: surface.Pointer): ()
        if x == nil or y == nil or dead or not visible then
          return
        end
        hovered = pointer
        if captured == pointer then
          point = { x = x, y = y }
          controller.move(state, point)
        end
      end,
      onLeave = function(_self: surface.Surface, pointer: surface.Pointer): ()
        if dead or not visible then
          return
        end
        if hovered == pointer then
          hovered = nil
        end
        if captured == pointer then
          controller.cancel(state)
        end
      end,
      onPress = function(_self: surface.Surface, x: number?, y: number?, pointer: surface.Pointer): ()
        if x == nil or y == nil or dead or not visible or captured ~= nil then
          return
        end
        hovered, captured = pointer, pointer
        point = { x = x, y = y }
        controller.press(state, point)
      end,
      onRelease = function(_self: surface.Surface, pointer: surface.Pointer): ()
        if dead or not visible then
          return
        end
        if captured == pointer then
          captured = nil
          controller.release(state, point)
        end
      end,
    }
    context:effect(function(): () -> ()
      return function(): ()
        dead = true
        offered.dead = true
        visible = false
        cancelInput()
      end
    end)
    surfaceService:offer(context, {
      name = 'desktop/manager',
      list = function(): { surface.Surface }
        return if visible and not dead then { offered } else {}
      end,
    })
    frameService:onUpdate(context, {
      phase = 'scene',
      run = function(_dt: number): ()
        if visible and not dead then
          controller.update(state)
        end
      end,
    })
    frameService:onKey(context, {
      phase = 'binding',
      order = -1000,
      run = function(event: frame.KeyEvent): boolean?
        if dead then
          return nil
        end
        if event.key == settings.toggleKey then
          if not event.isRepeat then
            visible = not visible
            cancelInput()
          end
          return true
        end
        if visible then
          return controller.key(state, event.key)
        end
        return nil
      end,
    })
    frameService:onText(context, {
      phase = 'binding',
      order = -1000,
      run = function(event: frame.TextEvent): boolean?
        return if visible and not dead then controller.text(state, event.text) else nil
      end,
    })
    frameService:onDraw(context, {
      phase = 'overlay',
      order = 1000,
      run = function(pass: Pass): ()
        if not visible or dead then
          return
        end
        pass:push 'transform'
        local ok, problem = pcall(function(): ()
          pass:transform(pose)
          pass:translate(-settings.width / 2, settings.height / 2, 0.002)
          pass:scale(settings.width / pixels, -settings.height / pixelHeight, 1)
          draw.render(pass, state.view, controller.options(state))
        end)
        pass:pop 'transform'
        if not ok then
          error(problem, 0)
        end
      end,
    })
  end,
}).definition

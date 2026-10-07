-- Provides a movable projected surface for inspecting and changing the session composition.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local surfaces = require '@lunette-contracts/surfaces'
local surface = require '@lunette-contracts/surface'
local composition = require '@lunette-contracts/composition'
local menu = require '@lunette-contracts/menu'
local quad = require '@lunette-contracts/quad'
local config = require '@lunette-plugins/desktop/manager/config'
local controller = require '@lunette-plugins/desktop/manager/controller'
local view = require '@lunette-plugins/desktop/manager/view'
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
    menu = menu.capability,
  },
  init = function(context: plugin.Context, settings: Settings): ()
    local compositionService = context:require(composition.capability)
    local frameService = context:require(frame.capability)
    local surfaceService = context:require(surfaces.capability)
    local menuService = context:require(menu.capability)
    local pixels = settings.pixels
    local pixelHeight = pixels * settings.height / settings.width
    local visible = settings.visible
    local dead = false
    local cancelling = false
    local pose = lovr.math.newMat4():translate(settings.position)
    local cancelInput: (surface.CancelReason) -> ()
    local state = controller.new(
      compositionService,
      brokers.watch(context),
      pixels,
      pixelHeight,
      function(records, sidebar): { string }
        return draw.wrapDetails(lovr.graphics.getDefaultFont(), records, sidebar)
      end,
      function(): ()
        if not dead then
          visible = false
          cancelInput 'hidden'
        end
      end
    )
    local hovered: surface.Pointer? = nil
    local captured: surface.Pointer? = nil
    local active: { [surface.Pointer]: { [lunette.PointerButton]: boolean } } = {}
    local scrollRemainder = 0
    local function clearInput(): ()
      hovered, captured = nil, nil
      scrollRemainder = 0
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
      project = function(_self: surface.Surface, origin: vector, direction: vector): (number?, number?, number?)
        if dead or not visible then
          return nil, nil, nil
        end
        return quad.project({
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
      onPointer = function(_self: surface.Surface, event: surface.PointerEvent): ()
        if dead or not visible or cancelling then
          return
        end
        local pointer, x, y = event.pointer, event.x, event.y
        if event.kind == 'press' then
          local button = event.button
          if button then
            local buttons = active[pointer] or {}
            active[pointer] = buttons
            buttons[button] = true
          end
        elseif event.kind == 'release' then
          local buttons = active[pointer]
          if buttons then
            buttons[event.button] = nil
            if next(buttons) == nil then
              active[pointer] = nil
            end
          end
        elseif event.kind == 'cancel' then
          local buttons = active[pointer]
          if buttons then
            buttons[event.button] = nil
            if next(buttons) == nil then
              active[pointer] = nil
            end
          end
        end
        if event.kind == 'leave' then
          if hovered == pointer then
            hovered = nil
          end
        elseif event.kind == 'enter' then
          hovered = pointer
        elseif event.kind == 'cancel' then
          if event.button == 'left' and captured == pointer then
            clearInput()
          end
        elseif event.kind == 'press' then
          if event.button ~= 'left' or not event.inside or captured ~= nil or x == nil or y == nil then
            return
          end
          hovered, captured = pointer, pointer
          controller.press(state, { x = x, y = y })
        elseif event.kind == 'move' then
          if event.inside then
            hovered = pointer
          end
          if captured == pointer and event.button == 'left' and x ~= nil and y ~= nil then
            controller.move(state, { x = x, y = y })
          end
        elseif event.kind == 'release' then
          if event.button == 'left' and captured == pointer then
            captured = nil
            if x ~= nil and y ~= nil then
              local released = { x = x, y = y }
              if event.inside then
                controller.release(state, released)
              else
                controller.move(state, released)
                controller.cancel(state)
              end
            else
              controller.cancel(state)
            end
          end
        elseif event.kind == 'scroll' then
          if not event.inside or x == nil or y == nil or event.dy == 0 then
            return
          end
          if captured ~= nil and captured ~= pointer then
            return
          end
          if x < state.view.viewport.x then
            scrollRemainder = 0
            view.zoom(state.view, { x = x, y = y }, math.exp(-event.dy / 600))
          elseif not state.edit then
            scrollRemainder += event.dy / 36
            local rows = if scrollRemainder > 0 then math.floor(scrollRemainder) else math.ceil(scrollRemainder)
            if rows ~= 0 then
              scrollRemainder -= rows
              state.scroll = math.max(0, state.scroll + rows)
              controller.update(state)
            end
          end
        end
      end,
    }
    cancelInput = function(reason: surface.CancelReason): ()
      if cancelling then
        return
      end
      cancelling = true
      local pointers = active
      active = {}
      clearInput()
      local failures: { string } = {}
      for pointer in pointers do
        local ok, problem = pcall(function(): ()
          pointer:cancel(offered, reason)
        end)
        if not ok then
          failures[#failures + 1] = tostring(problem)
        end
      end
      cancelling = false
      if #failures > 0 then
        error('desktop/manager: pointer cleanup: ' .. table.concat(failures, '; '), 0)
      end
    end
    context:effect(function(): () -> ()
      return function(): ()
        dead = true
        offered.dead = true
        visible = false
        cancelInput 'surface-dead'
      end
    end)
    menuService:register(context, {
      id = 'desktop/manager/open',
      label = 'Plugins',
      group = 'Session',
      order = 20,
      run = function(): ()
        if not dead and context:active() then
          visible = true
        end
      end,
    })
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
            cancelInput 'hidden'
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

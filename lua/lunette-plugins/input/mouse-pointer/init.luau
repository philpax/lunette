-- Drives one interaction pointer from the mouse while LÖVR's desktop window receives mouse input. The ray starts at
-- the head and points through a cursor that mouse movement turns, or, in the desktop simulator, through the window's
-- own cursor. The pointer and its seat are made at the first
-- movement, so a session without a mouse has no extra seat and draws no cursor.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local interaction = require '@lunette-contracts/interaction'
local surfaces = require '@lunette-contracts/surfaces'
local theme = require '@lunette-contracts/theme'
local passState = require '@lunette-plugins/graphics/pass-state'
local config = require '@self/config'
local cursor = require '@self/private/cursor'
local buttons = require '@self/private/buttons'

export type Config = config.Config
export type Settings = config.Settings

type Mouse = {
  read pointer: interaction.Pointer,
  read seat: lunette.Seat,
}

-- The ray of the latest pointing update, which the cursor is drawn along.
type Ray = {
  read origin: vector,
  read direction: vector,
}

local required: plugin.Declaration = {
  frame.capability,
  interaction.capability,
  surfaces.capability,
  theme.capability,
}

-- The view the desktop simulator shows in its window, or nil while a headset session runs. LÖVR answers the
-- simulator's view angles from the window.
local function simulatorView(): cursor.View?
  local headset = lovr.headset
  if not headset or headset.isActive() then
    return nil
  end
  local left, right, up, down = headset.getViewAngles(1)
  if not left or not right or not up or not down then
    return nil
  end
  return { left = left, right = right, up = up, down = down }
end

local function headPose(): Mat4?
  local headset = lovr.headset
  if not headset or not headset.isTracked 'head' then
    return nil
  end
  local x, y, z, angle, ax, ay, az = headset.getPose 'head'
  return lovr.math.newMat4():translate(x, y, z):rotate(angle, ax, ay, az)
end

-- The pointer's own seat gives native windows a separate pointer and keyboard focus from the controllers. The wheel
-- reaches the pointer as a rate over the frame, so the scroll scale converts a wheel unit to pixels and the push scale
-- converts it to metres, with no dead zone.
local function makeMouse(context: plugin.Context, settings: Settings): Mouse
  local interactionService: interaction.Service = context:require(interaction.capability)
  local made = context:resource(context, function(): (Mouse, () -> ())
    local seat = lunette.newSeat { name = 'mouse' }
    local ok, pointer = pcall(function(): interaction.Pointer
      return interactionService:newPointer(context, {
        seat = seat,
        tuning = { scrollScale = settings.scrollScale, scrollDeadZone = 0, reachScale = settings.pushScale },
      })
    end)
    if not ok then
      seat:destroy()
      error(pointer, 0)
    end
    local created: Mouse = { pointer = pointer, seat = seat }
    return created,
      function()
        local released, failure = pcall(function()
          pointer:destroy()
        end)
        if not seat.dead then
          seat:destroy()
        end
        if not released then
          error(failure, 0)
        end
      end
  end)
  return made
end

local function drawCursor(pass: Pass, position: vector, radius: number, color: theme.Color): ()
  local x, y, z = vector.unpack(position)
  passState.withRestore(pass, function()
    pass:setShader()
    pass:setMaterial(nil)
    pass:setColor(color[1], color[2], color[3], color[4])
    pass:setDepthTest()
    pass:setDepthWrite(false)
    pass:sphere(x, y, z, radius)
  end)
end

local function init(context: plugin.Context, settings: Settings): ()
  local frameService: frame.Service = context:require(frame.capability)
  local surfaceService: surfaces.Service = context:require(surfaces.capability)
  local themes: theme.Service = context:require(theme.capability)

  local aim = cursor.CENTRE
  local held = buttons.new()
  local wheelX, wheelY = 0, 0
  local mouse: Mouse? = nil
  local ray: Ray? = nil
  local withdrawn = false

  frameService:onMouse(context, {
    run = function(event: frame.HostMouseEvent)
      if event.kind == 'move' then
        -- In the simulator the ray follows the window's own cursor, except while the window holds the mouse in
        -- relative mode to turn the head, where the cursor has no place and the aim stays put.
        local view = simulatorView()
        if not view then
          aim = cursor.move(aim, event.dx, event.dy, settings)
        elseif lovr.system.getMouseMode() ~= 'relative' then
          local width, height = lovr.system.getWindowDimensions()
          if width > 0 and height > 0 then
            aim = cursor.fromWindow(event.x, event.y, width, height, view)
          end
        end
        if not mouse then
          mouse = makeMouse(context, settings)
        end
      elseif event.kind == 'press' then
        local button = buttons.fromNumber(event.button)
        if button then
          buttons.press(held, button)
        end
      elseif event.kind == 'release' then
        local button = buttons.fromNumber(event.button)
        if button then
          buttons.release(held, button)
        end
      elseif mouse then
        wheelX += event.dx
        wheelY += event.dy
      end
    end,
  })

  -- Picking follows this frame's scene geometry, as the controller rays do. The ray applies no aim filter and no
  -- trigger lock, because a mouse does not move when its button is pressed.
  frameService:onUpdate(context, {
    phase = 'pointing',
    run = function(dt: number)
      local current = mouse
      if not current then
        return
      end
      local head = headPose()
      if not head then
        ray = nil
        if not withdrawn then
          withdrawn = true
          current.pointer:withdraw()
        end
        return
      end
      withdrawn = false
      local pose = cursor.pose(head, aim)
      local origin, direction = cursor.ray(pose)
      ray = { origin = origin, direction = direction }
      -- A frame without elapsed time cannot carry a rate, so its wheel distance waits for the next frame.
      local scrollX, scrollY = 0, 0
      if dt > 0 then
        scrollX, scrollY = wheelX / dt, wheelY / dt
        wheelX, wheelY = 0, 0
      end
      current.pointer:update({
        pose = pose,
        origin = origin,
        direction = direction,
        buttons = buttons.sample(held),
        grip = false,
        scrollX = scrollX,
        scrollY = scrollY,
        dt = dt,
      }, surfaceService:all())
    end,
  })

  -- The cursor draws with the controller feedback, after all scene and overlay UI, so a panel never hides it.
  frameService:onDraw(context, {
    phase = 'feedback',
    run = function(pass: Pass)
      local current, line = mouse, ray
      if not current or not line or current.pointer.dead then
        return
      end
      local pointer = current.pointer
      local hovered = pointer.hovered ~= nil
      local distance = if hovered and pointer.distance then pointer.distance else settings.distance
      local colors = themes:current().theme.colors
      local color = if hovered then settings.hoverColor or colors.pointerHovered else settings.color or colors.pointer
      drawCursor(pass, line.origin + line.direction * distance, distance * settings.cursorAngle, color)
    end,
  })
end

return plugin.consumer<<Config, Settings>> {
  name = 'desktop/mouse-pointer',
  requires = required,
  schema = config.schema,
  init = init,
}

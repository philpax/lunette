-- The recovery panel: a flat quad that draws with LÖVR passes and offers itself for picking, without the toolkit.
-- An action runs on a release over the action that the same pointer pressed, so a press that slides off cancels.

local quad = require '@lunette-contracts/quad'
local vocabulary = require '@lunette-contracts/vocabulary'
local passState = require '@lunette-plugins/graphics/pass-state'
local config = require '../config'
local layout = require './layout'

local panel = {}

export type Settings = config.Settings
export type ActionId = layout.ActionId

export type Options = {
  read activate: (ActionId) -> (),
  read live: () -> boolean,
}

-- The surface fields picking reads, and the methods the interaction service calls.
export type Surface = {
  kind: nil,
  source: nil,
  dead: boolean,
  grabbable: boolean,
  pickPriority: number,
  pose: Mat4,
  width: number,
  height: number,
  raycast: (vocabulary.Surface, vector, vector, boolean?) -> (number?, number?, number?),
  onPointer: (vocabulary.Surface, vocabulary.PointerEvent) -> (),
  setPose: (vocabulary.Surface, Mat4) -> (),
}

export type Panel = {
  read surface: Surface,
  read visible: (Panel) -> boolean,
  read show: (Panel, layout.Content) -> (),
  read hide: (Panel) -> (),
  read draw: (Panel, Pass) -> (),
  read dispose: (Panel) -> (),
}

-- A pose `distance` metres ahead of the head along its horizontal facing and `drop` metres below it, turned to face
-- the head. A head looking straight up or down faces the panel along -z.
function panel.placement(head: Mat4, distance: number, drop: number): Mat4
  local x, y, z = head:getPosition()
  local fx, _, fz = head:mul(0, 0, -1, 0)
  local length = math.sqrt(fx * fx + fz * fz)
  if not (length > 1e-6) then
    fx, fz, length = 0, -1, 1
  end
  fx, fz = fx / length, fz / length
  return lovr.math
    .newMat4()
    :translate(x + fx * distance, y - drop, z + fz * distance)
    :rotate(math.atan2(-fx, -fz), 0, 1, 0)
end

local function headPose(): Mat4
  local headset = lovr.headset
  if headset then
    return lovr.math.newMat4(headset.getPose 'head')
  end
  return lovr.math.newMat4():translate(0, 1.5, 0)
end

local function setColor(pass: Pass, color: { read [number]: number }): ()
  pass:setColor(color[1], color[2], color[3], color[4])
end

function panel.new(settings: Settings, options: Options): Panel
  local limits: layout.Limits = { recentErrors = settings.recentErrors, columns = settings.columns }
  local scale = settings.width / layout.WIDTH
  local logicalHeight = layout.height(limits)
  local shown = false
  local current: layout.Layout? = nil
  local hovered: { [vocabulary.Pointer]: ActionId } = {}
  local pressed: { [vocabulary.Pointer]: ActionId } = {}

  local function actionAt(x: number?, y: number?): layout.Action?
    local placed = current
    if placed == nil or x == nil or y == nil then
      return nil
    end
    return layout.hit(placed, x, y)
  end

  local surface: Surface
  surface = {
    kind = nil,
    source = nil,
    dead = false,
    grabbable = true,
    pickPriority = settings.pickPriority,
    pose = lovr.math.newMat4(),
    width = settings.width,
    height = logicalHeight * scale,
    raycast = function(
      _self: vocabulary.Surface,
      origin: vector,
      direction: vector,
      backFace: boolean?
    ): (number?, number?, number?)
      if surface.dead or not shown or not options.live() then
        return nil, nil, nil
      end
      return quad.hit({
        pose = surface.pose,
        width = surface.width,
        height = surface.height,
        pixelWidth = layout.WIDTH,
        pixelHeight = logicalHeight,
        backFace = backFace,
      }, origin, direction)
    end,
    onPointer = function(_self: vocabulary.Surface, event: vocabulary.PointerEvent): ()
      local pointer = event.pointer
      if event.kind == 'leave' or event.kind == 'cancel' then
        hovered[pointer] = nil
        pressed[pointer] = nil
        return
      end
      local action = if event.inside then actionAt(event.x, event.y) else nil
      if event.kind == 'enter' or event.kind == 'move' then
        hovered[pointer] = if action then action.id else nil
      elseif event.kind == 'press' then
        pressed[pointer] = if event.button == 'left' and action and action.enabled then action.id else nil
      elseif event.kind == 'release' and event.button == 'left' then
        local started = pressed[pointer]
        pressed[pointer] = nil
        if started and action and action.id == started and action.enabled and shown and options.live() then
          options.activate(started)
        end
      end
    end,
    setPose = function(_self: vocabulary.Surface, pose: Mat4): ()
      if not surface.dead then
        surface.pose:set(pose)
      end
    end,
  }

  local function release(reason: vocabulary.CancelReason): ()
    local held = pressed
    pressed = {}
    table.clear(hovered)
    for pointer in held do
      pcall(function(): ()
        pointer:cancel(surface, reason)
      end)
    end
  end

  return {
    surface = surface,
    visible = function(_self: Panel): boolean
      return shown and not surface.dead
    end,
    show = function(_self: Panel, content: layout.Content): ()
      if surface.dead then
        return
      end
      if not shown then
        surface.pose:set(panel.placement(headPose(), settings.distance, settings.drop))
        shown = true
      end
      current = layout.build(content, limits)
    end,
    hide = function(_self: Panel): ()
      if shown then
        shown = false
        current = nil
        release 'hidden'
      end
    end,
    draw = function(_self: Panel, pass: Pass): ()
      local placed = current
      if not shown or surface.dead or placed == nil then
        return
      end
      local width, height = surface.width, surface.height
      local function at(x: number, y: number): (number, number)
        return x * scale - width / 2, height / 2 - y * scale
      end
      passState.withRestore(pass, function(): ()
        pass:setShader()
        pass:setMaterial(nil)
        pass:transform(surface.pose)
        setColor(pass, settings.background)
        pass:plane(0, 0, 0, width, height, 0, 0, 0, 0, 'fill', 1, 1)
        local active: { [ActionId]: boolean } = {}
        for _, id in hovered do
          active[id] = true
        end
        for _, entry in placed.actions do
          local rect, action = entry.rect, entry.action
          local x, y = at(rect.x + rect.width / 2, rect.y + rect.height / 2)
          setColor(
            pass,
            if not action.enabled
              then settings.disabled
              elseif active[action.id] then settings.hovered
              else settings.button
          )
          pass:plane(x, y, 0.002, rect.width * scale, rect.height * scale, 0, 0, 0, 0, 'fill', 1, 1)
          setColor(pass, settings.foreground)
          local labelY = if action.note then y + rect.height * scale * 0.18 else y
          local lx = at(rect.x + 20, 0)
          pass:text(action.label, lx, labelY, 0.004, 26 * scale, 0, 0, 1, 0, 0, 'left', 'middle')
          local note = action.note
          if note then
            pass:text(note, lx, y - rect.height * scale * 0.22, 0.004, 18 * scale, 0, 0, 1, 0, 0, 'left', 'middle')
          end
        end
        setColor(pass, settings.foreground)
        for _, line in placed.lines do
          local x, y = at(line.x, line.y)
          pass:text(line.text, x, y, 0.004, line.size * scale, 0, 0, 1, 0, 0, 'left', 'middle')
        end
      end)
    end,
    dispose = function(_self: Panel): ()
      if not surface.dead then
        release 'surface-dead'
        surface.dead = true
        shown = false
        current = nil
      end
    end,
  }
end

return panel

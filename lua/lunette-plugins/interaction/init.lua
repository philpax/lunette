-- Owner-scoped pointer interaction with activation-local focus and grab state.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contracts = require '@lunette-contracts/interaction'
local panelsContract = require '@lunette-contracts/panels'
local grab = require '@lunette-plugins/interaction/grab'
local pose = require '@lunette-plugins/interaction/pose'

type Service = contracts.Service
type Pointer = contracts.Pointer
type Surface = contracts.Surface
type PointerState = grab.PointerState

local TUNING: contracts.Tuning = {
  reach = 8,
  grabDeadZone = 0.006,
  scrollScale = 900,
  scrollDeadZone = 0.2,
  reachScale = 1.2,
  reachMinimum = 0.2,
  reachMaximum = 6,
  resizeMinimum = 0.15,
  resizeMaximum = 4,
  button = 'left',
}
local POSE_PROPERTY = 'mullion.pose'

local function deadZone(value: number, dead: number): number
  if value ~= value or not (dead < 1) or math.abs(value) <= dead then
    return 0
  end
  return (value < 0 and -1 or 1) * (math.abs(value) - dead) / (1 - dead)
end

local function pick(
  surfaces: { Surface },
  origin: vector,
  direction: vector,
  tuning: contracts.Tuning
): (Surface?, number?, number?, number?)
  local length = direction:length()
  if not (length > 0) then
    return nil, nil, nil, nil
  end
  local ray = direction * (1 / length)
  local hit: Surface?, x: number?, y: number?, distance: number?
  for _, candidate in ipairs(surfaces) do
    if not candidate.dead then
      local cx, cy, cd = candidate:raycast(origin, ray)
      if cx and cy and cd and cd <= tuning.reach and (not distance or cd < distance) then
        hit, x, y, distance = candidate, cx, cy, cd
      end
    end
  end
  return hit, x, y, distance
end

local function storePose(target: Surface): boolean
  if target.dead or target.kind ~= 'window' or target.source.dead or not target.pose then
    return false
  end
  return target.source:setProperty(POSE_PROPERTY, pose.encode(target.pose)) and true
end

local function restorePose(target: Surface): boolean
  if target.dead or target.kind ~= 'window' or target.source.dead then
    return false
  end
  local kept = pose.decode(target.source:getProperty(POSE_PROPERTY))
  if not kept or not target.setPose then
    return false
  end
  target:setPose(kept)
  return true
end

local function emitDropped(context: plugin.Context, panels: panelsContract.Service, target: Surface, pointer: Pointer)
  if not context:active() then
    return
  end
  if target.kind == 'window' or target.kind == 'monitor' then
    local panel = panels:forSource(target.source)
    if panel then
      panels:emitDropped(context, panel, pointer)
    end
  end
end

local function init(context: plugin.Context): Service
  local active = true
  local pointers: { Pointer } = {}
  local states: { [Pointer]: PointerState } = {}
  local focusedSeat: lunette.Seat? = nil
  local focusedSink: lunette.Sink? = nil
  local function checkActive()
    if not active or not context:active() then
      error 'interaction: service is no longer active'
    end
  end
  local panels: panelsContract.Service = context:require(panelsContract.capability)
  local carrying = grab.new {
    pointers = function(): { PointerState }
      local result: { PointerState } = {}
      for _, pointer in ipairs(pointers) do
        local state = states[pointer]
        if state and not state.dead then
          result[#result + 1] = state
        end
      end
      return result
    end,
    state = function(pointer: Pointer): PointerState
      return assert(states[pointer], 'interaction: unknown pointer')
    end,
    storePose = storePose,
    emitDropped = function(target: Surface, pointer: Pointer)
      emitDropped(context, panels, target, pointer)
    end,
  }
  local function newPointer(owner: contracts.Owner, options: contracts.PointerOptions?): Pointer
    checkActive()
    context:checkOwner(owner)
    local seat: lunette.Seat? = options and options.seat
    local state: {
      tuning: contracts.Tuning,
      handPosition: { number }?,
      grabbed: Surface?,
      grab: grab.GrabState?,
      scaling: contracts.Scaling?,
      dead: boolean,
      pointer: Pointer?,
      seat: lunette.Seat?,
      hovered: Surface?,
      hitX: number?,
      hitY: number?,
      distance: number?,
      gripped: boolean,
      pressed: boolean,
      pressedSink: lunette.Sink?,
      pressedSurface: Surface?,
    } =
      {
        tuning = options and options.tuning or TUNING,
        handPosition = nil,
        grabbed = nil,
        grab = nil,
        scaling = nil,
        dead = false,
        pointer = nil,
        seat = seat,
        hovered = nil,
        hitX = nil,
        hitY = nil,
        distance = nil,
        gripped = false,
        pressed = false,
        pressedSink = nil,
        pressedSurface = nil,
      }
    local fields = state
    local function live(): boolean
      return active and context:active() and not state.dead
    end
    local function focus(sink: lunette.Sink?)
      if seat and not seat.dead then
        seat:setFocus(sink)
      end
      focusedSeat, focusedSink = seat, sink
    end
    local function hover(pointer: Pointer, hit: Surface?)
      local previous = fields.hovered
      if previous == hit then
        return
      end
      fields.hovered = hit
      if hit and hit.setHighlighted then
        hit:setHighlighted(true)
      end
      if previous then
        if previous.setHighlighted then
          previous:setHighlighted(false)
        end
        local sink = previous.sink and previous:sink()
        if sink and not sink.dead and (not seat or not seat.dead) then
          sink:leave(seat)
        end
        if previous.onLeave then
          previous:onLeave(pointer)
        end
      end
    end
    local function button(pointer: Pointer, pressed: boolean, sink: lunette.Sink?, surface: Surface?)
      if pressed == fields.pressed then
        return
      end
      fields.pressed = pressed
      if pressed then
        if sink and not sink.dead and (not seat or not seat.dead) then
          fields.pressedSink = sink
          sink:button(state.tuning.button, true, seat)
          focus(sink)
        elseif surface and surface.onPress then
          fields.pressedSurface = surface
          surface:onPress(fields.hitX, fields.hitY, pointer)
        end
        return
      end
      local target, released = fields.pressedSink, fields.pressedSurface
      fields.pressedSink, fields.pressedSurface = nil, nil
      if target and not target.dead and (not seat or not seat.dead) then
        target:button(state.tuning.button, false, seat)
      end
      if released and released.onRelease then
        released:onRelease(pointer)
      end
    end
    local function withdraw(pointer: Pointer)
      if state.grabbed then
        carrying.endGrab(pointer)
      end
      button(pointer, false, nil, nil)
      hover(pointer, nil)
      fields.gripped = false
    end
    local cleanupEffect: plugin.Effect? = nil
    local function destroyRaw(self: Pointer): boolean
      if state.dead then
        return false
      end
      state.dead = true
      withdraw(self)
      local index = table.find(pointers, self)
      if index then
        table.remove(pointers, index)
      end
      states[self] = nil
      return true
    end
    local methods = {
      hover = function(self: Pointer, hit: Surface?)
        if live() then
          hover(self, hit)
        end
      end,
      focus = function(_self: Pointer, sink: lunette.Sink?)
        if live() then
          focus(sink)
        end
      end,
      setButton = function(self: Pointer, pressed: boolean, sink: lunette.Sink?, surface: Surface?)
        if live() then
          button(self, pressed, sink, surface)
        end
      end,
      withdraw = function(self: Pointer)
        if not state.dead then
          withdraw(self)
        end
      end,
      destroy = function(self: Pointer): boolean
        if state.dead then
          return false
        end
        local effect = cleanupEffect
        if effect then
          effect:dispose()
          return true
        end
        return destroyRaw(self)
      end,
      beginGrab = function(self: Pointer, target: Surface, handPose: Mat4?): boolean
        if not live() or target.dead then
          return false
        end
        return carrying.beginGrab(self, target, handPose)
      end,
      scaleWith = function(self: Pointer, handPose: Mat4?)
        if live() then
          carrying.scaleWith(self, handPose)
        end
      end,
      push = function(self: Pointer, amount: number, dt: number)
        if live() then
          carrying.push(self, amount, dt)
        end
      end,
      dragTo = function(self: Pointer, handPose: Mat4?)
        if live() then
          carrying.dragTo(self, handPose)
        end
      end,
      endGrab = function(self: Pointer): boolean
        if not live() then
          return false
        end
        return carrying.endGrab(self)
      end,
      update = function(self: Pointer, input: contracts.Input, surfaces: { Surface })
        if not live() then
          return
        end
        state.handPosition = input.pose and { input.pose:getPosition() } or nil
        local gripped = input.grip
        local grabbed = state.grabbed
        if grabbed then
          if grabbed.dead or not gripped then
            carrying.endGrab(self)
          elseif state.scaling then
            carrying.scaleWith(self, input.pose)
          else
            carrying.push(self, input.scrollY or 0, input.dt or 0)
            carrying.dragTo(self, input.pose)
          end
          fields.gripped = gripped
          return
        end
        local hit, x, y, distance = pick(surfaces, input.origin, input.direction, state.tuning)
        hover(self, hit)
        fields.hitX, fields.hitY, fields.distance = x, y, distance
        if
          hit
          and gripped
          and not fields.gripped
          and hit.grabbable ~= false
          and carrying.beginGrab(self, hit, input.pose)
        then
          fields.gripped = true
          return
        end
        fields.gripped = gripped
        local sink = hit and hit.sink and hit:sink() or nil
        if sink and not sink.dead and (not seat or not seat.dead) and x and y then
          sink:pointer(x, y, seat)
          local scale = state.tuning.scrollScale * (input.dt or 0)
          local dx = deadZone(input.scrollX or 0, state.tuning.scrollDeadZone) * scale
          local dy = -deadZone(input.scrollY or 0, state.tuning.scrollDeadZone) * scale
          if dx ~= 0 or dy ~= 0 then
            sink:scroll(dx, dy, seat)
          end
        elseif hit and hit.onHover then
          hit:onHover(x, y, self)
        end
        button(self, input.trigger, sink, hit)
      end,
    }
    local public: Pointer = setmetatable(state, { __index = methods })
    state.pointer = public
    local acquired = owner:effect(function()
      pointers[#pointers + 1] = public
      states[public] = state
      local nativeCleanup = context:effect(function()
        return function()
          destroyRaw(public)
        end
      end)
      return function()
        cleanupEffect = nil
        nativeCleanup:dispose()
      end
    end)
    if not state.dead then
      cleanupEffect = acquired
    end
    return public
  end
  context:effect(function()
    return function()
      active = false
      for _, pointer in ipairs(table.clone(pointers)) do
        pointer:destroy()
      end
      focusedSeat, focusedSink = nil, nil
    end
  end)
  return {
    TUNING = TUNING,
    POSE_PROPERTY = POSE_PROPERTY,
    pick = function(
      _self: Service,
      surfaces: { Surface },
      origin: vector,
      direction: vector,
      tuning: contracts.Tuning?
    )
      return pick(surfaces, origin, direction, tuning or TUNING)
    end,
    scrollDelta = function(_self: Service, x: number, y: number, dt: number?, tuning: contracts.Tuning?)
      local current = tuning or TUNING
      local scale = current.scrollScale * (dt or 0)
      return deadZone(x, current.scrollDeadZone) * scale, -deadZone(y, current.scrollDeadZone) * scale
    end,
    storePose = function(_self: Service, target: Surface): boolean
      checkActive()
      return storePose(target)
    end,
    restorePose = function(_self: Service, target: Surface): boolean
      checkActive()
      return restorePose(target)
    end,
    newPointer = function(_self: Service, owner: contracts.Owner, options: contracts.PointerOptions?): Pointer
      return newPointer(owner, options)
    end,
    pointers = function(_self: Service): { Pointer }
      return table.clone(pointers)
    end,
    focused = function(_self: Service): (lunette.Seat?, lunette.Sink?)
      return focusedSeat, focusedSink
    end,
    setFocus = function(_self: Service, seat: lunette.Seat?, sink: lunette.Sink?)
      checkActive()
      focusedSeat, focusedSink = seat, sink
    end,
  }
end

local required = { panels = panelsContract.capability }
local provided = { interaction = contracts.capability }
return plugin.define(
  function(config: {}): {}
    return config
  end,
  required,
  provided,
  function(context: plugin.Context, _config: {}, publish: plugin.Publisher)
    publish:provide(contracts.capability, init(context))
  end
)

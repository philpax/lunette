-- Pointer release runs with its owner, and failures remain that owner's failures. Focus grants and drop listeners use the provider context. See docs/dev/lua-api.md#pointers-and-interaction.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contracts = require '@lunette-contracts/interaction'
local dropsContract = require '@lunette-contracts/drops'
local focusContract = require '@lunette-contracts/focus'
local vocabulary = require '@lunette-contracts/vocabulary'
local grab = require '@lunette-plugins/interaction/grab'
local picking = require '@lunette-plugins/interaction/picking'

type Service = contracts.Service
type Pointer = contracts.Pointer
type Surface = contracts.Surface

local config = require '@lunette-plugins/interaction/config'

export type DriveBase = config.DriveBase
export type Drive = config.Drive
export type ConstrainBase = config.ConstrainBase
export type Constrain = config.Constrain
export type Settings = config.Settings
export type Config = config.Config

type State = {
  tuning: contracts.Tuning,
  handPosition: vector?,
  grabbed: Surface?,
  grab: grab.GrabState?,
  scaling: grab.Scaling?,
  dead: boolean,
  pointer: Pointer?,
  seat: lunette.Seat?,
  pulse: ((contracts.Haptic) -> boolean)?,
  hovered: Surface?,
  hitX: number?,
  hitY: number?,
  distance: number?,
  gripped: boolean,
  pressed: { [lunette.PointerButton]: boolean },
  pressedSink: { [lunette.PointerButton]: lunette.Sink },
  pressedSurface: { [lunette.PointerButton]: Surface },
}

local READABLE: { [string]: boolean } = {
  seat = true,
  tuning = true,
  hovered = true,
  hitX = true,
  hitY = true,
  distance = true,
  grabbed = true,
  dead = true,
}

local BUTTONS: { [string]: boolean } = {}
for _, button in ipairs(vocabulary.POINTER_BUTTONS) do
  BUTTONS[button] = true
end

local NO_SEAT = table.freeze {}

local function unchanged(_surface: Surface, pose: Mat4): Mat4
  return pose
end

local function build(context: plugin.Context, settings: Settings): Service
  local active = true
  local TUNING = settings.tuning
  local pointers: { Pointer } = {}
  local states: { [Pointer]: State } = {}
  local dropService: dropsContract.Service = context:require(dropsContract.capability)
  local focusService: focusContract.Service = context:require(focusContract.capability)
  -- A pointer ending withdraws its grant when no later pointer owns focus for that seat.
  local grantors: { [unknown]: State } = {}
  local grants: { [unknown]: plugin.Effect } = {}

  local carrying = grab.new {
    pointers = function(): { grab.PointerState }
      local result: { grab.PointerState } = {}
      for _, pointer in ipairs(pointers) do
        local state = states[pointer]
        if state and not state.dead then
          result[#result + 1] = state
        end
      end
      return result
    end,
    state = function(pointer: Pointer): grab.PointerState
      return assert(states[pointer], 'interaction: unknown pointer')
    end,
    -- A grab ended by this activation's own teardown is not announced: the
    -- context can no longer act as an owner.
    dropped = function(target: Surface, pointer: Pointer)
      if active and context:active() then
        dropService:emit(context, { surface = target, pointer = pointer })
      end
    end,
    constrain = function(target: Surface, pose: Mat4): Mat4
      return settings.constrain(target, pose, unchanged)
    end,
  }

  local function live(state: State): boolean
    return active and context:active() and not state.dead
  end

  local function giveFocus(state: State, sink: lunette.Sink?): ()
    local key: unknown = state.seat or NO_SEAT
    grants[key] = focusService:setFocus(context, { seat = state.seat, sink = sink })
    grantors[key] = state
  end

  local function withdrawFocus(state: State): ()
    local key: unknown = state.seat or NO_SEAT
    if grantors[key] ~= state then
      return
    end
    grantors[key] = nil
    local effect = grants[key]
    grants[key] = nil
    if effect then
      effect:dispose()
    end
  end

  -- A highlight stays active while another pointer still hovers the surface.
  local function hoveredByAnother(state: State, target: Surface): boolean
    for _, other in pairs(states) do
      if other ~= state and not other.dead and other.hovered == target then
        return true
      end
    end
    return false
  end

  local function seatLive(state: State): boolean
    local seat = state.seat
    return not seat or not seat.dead
  end

  local function hover(state: State, pointer: Pointer, hit: Surface?)
    local previous = state.hovered
    if previous == hit then
      return
    end
    state.hovered = hit
    if hit and hit.setHighlighted then
      hit:setHighlighted(true)
    end
    if previous then
      if previous.setHighlighted and not hoveredByAnother(state, previous) then
        previous:setHighlighted(false)
      end
      local sink = previous.sink and previous:sink()
      if sink and not sink.dead and seatLive(state) then
        sink:leave(state.seat)
      end
      if previous.onLeave then
        previous:onLeave(pointer)
      end
    end
  end

  local function press(
    state: State,
    pointer: Pointer,
    button: lunette.PointerButton,
    pressed: boolean,
    sink: lunette.Sink?,
    surface: Surface?
  )
    if pressed == (state.pressed[button] == true) then
      return
    end
    state.pressed[button] = if pressed then true else nil
    if pressed then
      if sink and not sink.dead and seatLive(state) then
        state.pressedSink[button] = sink
        sink:button(button, true, state.seat)
        if settings.focusOnPress then
          giveFocus(state, sink)
        end
      elseif surface and surface.onPress then
        state.pressedSurface[button] = surface
        surface:onPress(state.hitX, state.hitY, pointer)
      end
      return
    end
    local target, released = state.pressedSink[button], state.pressedSurface[button]
    state.pressedSink[button], state.pressedSurface[button] = nil, nil
    if target and not target.dead and seatLive(state) then
      target:button(button, false, state.seat)
    end
    if released and released.onRelease then
      released:onRelease(pointer)
    end
  end

  local function withdraw(state: State, pointer: Pointer)
    if state.grabbed then
      carrying.endGrab(pointer)
    end
    for _, button in ipairs(vocabulary.POINTER_BUTTONS) do
      press(state, pointer, button, false, nil, nil)
    end
    hover(state, pointer, nil)
    state.gripped = false
  end

  local function defaultDrive(pointer: Pointer, input: contracts.Input, surfaces: { read [number]: Surface }): ()
    local state = states[pointer]
    if not state then
      error('interaction: drive was given a pointer this activation did not make', 2)
    end
    if not live(state) then
      return
    end
    state.handPosition = input.pose and vector.pack(input.pose:getPosition()) or nil
    local gripped = input.grip
    local grabbed = state.grabbed
    if grabbed then
      if grabbed.dead or not gripped then
        carrying.endGrab(pointer)
      elseif state.scaling then
        carrying.scaleWith(pointer, input.pose)
      else
        carrying.push(pointer, input.scrollY or 0, input.dt or 0)
        carrying.dragTo(pointer, input.pose)
      end
      state.gripped = gripped
      return
    end
    local hit, x, y, distance = picking.pick(surfaces, input.origin, input.direction, state.tuning.reach)
    hover(state, pointer, hit)
    state.hitX, state.hitY, state.distance = x, y, distance
    if
      hit
      and gripped
      and not state.gripped
      and hit.grabbable ~= false
      and carrying.beginGrab(pointer, hit, input.pose)
    then
      state.gripped = true
      return
    end
    state.gripped = gripped
    local sink = hit and hit.sink and hit:sink() or nil
    if sink and not sink.dead and seatLive(state) and x and y then
      sink:pointer(x, y, state.seat)
      local dx, dy = picking.scrollDelta {
        x = input.scrollX or 0,
        y = input.scrollY or 0,
        dt = input.dt,
        tuning = state.tuning,
      }
      if dx ~= 0 or dy ~= 0 then
        sink:scroll(dx, dy, state.seat)
      end
    elseif hit and hit.onHover then
      hit:onHover(x, y, pointer)
    end
    local held = input.buttons or {}
    for _, button in ipairs(vocabulary.POINTER_BUTTONS) do
      press(state, pointer, button, held[button] == true, sink, hit)
    end
  end

  local function newPointer(owner: contracts.Owner, options: contracts.PointerOptions?): Pointer
    context:checkOwner(owner)
    local pulse = options and options.vibrate
    if pulse ~= nil and type(pulse) ~= 'function' then
      error("interaction: a pointer's vibrate is a function, not a " .. type(pulse), 3)
    end
    local state: State = {
      tuning = if options and options.tuning
        then {
          reach = options.tuning.reach or TUNING.reach,
          grabDeadZone = options.tuning.grabDeadZone or TUNING.grabDeadZone,
          scrollScale = options.tuning.scrollScale or TUNING.scrollScale,
          scrollDeadZone = options.tuning.scrollDeadZone or TUNING.scrollDeadZone,
          reachScale = options.tuning.reachScale or TUNING.reachScale,
          reachMinimum = options.tuning.reachMinimum or TUNING.reachMinimum,
          reachMaximum = options.tuning.reachMaximum or TUNING.reachMaximum,
          resizeMinimum = options.tuning.resizeMinimum or TUNING.resizeMinimum,
          resizeMaximum = options.tuning.resizeMaximum or TUNING.resizeMaximum,
        }
        else TUNING,
      handPosition = nil,
      grabbed = nil,
      grab = nil,
      scaling = nil,
      dead = false,
      pointer = nil,
      seat = options and options.seat,
      pulse = pulse,
      hovered = nil,
      hitX = nil,
      hitY = nil,
      distance = nil,
      gripped = false,
      pressed = {},
      pressedSink = {},
      pressedSurface = {},
    }
    local cleanupEffect: plugin.Effect? = nil
    local public: Pointer
    -- The pointer leaves the registry before releases run, and every release is attempted before failure is raised.
    local function destroyRaw(): boolean
      if state.dead then
        return false
      end
      state.dead = true
      local withdrawn, withdrawal = pcall(withdraw, state, public)
      local index = table.find(pointers, public)
      if index then
        table.remove(pointers, index)
      end
      local revoked, revocation = pcall(withdrawFocus, state)
      states[public] = nil
      if not withdrawn then
        error(withdrawal, 0)
      end
      if not revoked then
        error(revocation, 0)
      end
      return true
    end
    local methods = {
      hover = function(self: Pointer, hit: Surface?)
        if live(state) then
          hover(state, self, hit)
        end
      end,
      focus = function(_self: Pointer, sink: lunette.Sink?)
        if live(state) then
          giveFocus(state, sink)
        end
      end,
      setButton = function(self: Pointer, given: contracts.ButtonState)
        local button = given.button or 'left'
        if not BUTTONS[button] then
          error('interaction: setButton presses a pointer button, not ' .. tostring(button), 2)
        end
        if live(state) then
          press(state, self, button, given.pressed, given.sink, given.surface)
        end
      end,
      withdraw = function(self: Pointer)
        if not state.dead then
          withdraw(state, self)
        end
      end,
      -- The release runs here, on the caller's stack, so its failure is the
      -- caller's; the owner's effect is then disposed with nothing left to do.
      destroy = function(_self: Pointer): boolean
        if state.dead then
          return false
        end
        local effect = cleanupEffect
        cleanupEffect = nil
        local ok, failure = pcall(destroyRaw)
        if effect then
          effect:dispose()
        end
        if not ok then
          error(failure, 0)
        end
        return true
      end,
      beginGrab = function(self: Pointer, target: Surface, handPose: Mat4?): boolean
        if not live(state) or target.dead then
          return false
        end
        return carrying.beginGrab(self, target, handPose)
      end,
      scaleWith = function(self: Pointer, handPose: Mat4?)
        if live(state) then
          carrying.scaleWith(self, handPose)
        end
      end,
      push = function(self: Pointer, given: contracts.Push)
        if live(state) then
          carrying.push(self, given.deflection, given.dt)
        end
      end,
      dragTo = function(self: Pointer, handPose: Mat4?)
        if live(state) then
          carrying.dragTo(self, handPose)
        end
      end,
      endGrab = function(self: Pointer): boolean
        if not live(state) then
          return false
        end
        return carrying.endGrab(self)
      end,
      vibrate = function(_self: Pointer, haptic: contracts.Haptic): boolean
        local send = state.pulse
        if not live(state) or not send then
          return false
        end
        return send(haptic) == true
      end,
      update = function(self: Pointer, input: contracts.Input, surfaces: { read [number]: Surface })
        if live(state) then
          settings.drive(self, input, surfaces, defaultDrive)
        end
      end,
    }
    local view = setmetatable({}, {
      __index = function(_view: unknown, key: unknown): unknown
        if type(key) == 'string' and READABLE[key] then
          return (state :: any)[key]
        end
        return (methods :: any)[key]
      end,
      __newindex = function(_view: unknown, key: unknown): ()
        error('interaction: a pointer is read-only, so ' .. tostring(key) .. ' cannot be assigned', 2)
      end,
    })
    public = (view :: any) :: Pointer
    state.pointer = public
    local acquired = owner:effect(function()
      pointers[#pointers + 1] = public
      states[public] = state
      return function()
        cleanupEffect = nil
        destroyRaw()
      end
    end)
    if not state.dead then
      cleanupEffect = acquired
    end
    return public
  end
  -- Provider shutdown releases grants that remain after owners unload.
  context:effect(function()
    return function()
      active = false
      for _, pointer in ipairs(table.clone(pointers)) do
        pointer:destroy()
      end
      table.clear(grantors)
      table.clear(grants)
    end
  end)
  -- The published service is revoked with this activation, so its methods need no liveness guard; pointers
  -- outlive the call that made them and check the activation themselves.
  return {
    TUNING = TUNING,
    newPointer = function(_self: Service, owner: contracts.Owner, options: contracts.PointerOptions?): Pointer
      return newPointer(owner, options)
    end,
    pointers = function(_self: Service): { Pointer }
      return table.clone(pointers)
    end,
  }
end

return plugin.provider<<Config, Settings, Service>> {
  name = 'interaction',
  capability = contracts.capability,
  requires = { drops = dropsContract.capability, focus = focusContract.capability },
  schema = config,
  build = build,
}

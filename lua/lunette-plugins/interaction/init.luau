-- Owns pointer lifetimes and orders input capture, native focus, and spatial grabs.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contracts = require '@lunette-contracts/interaction'
local dropsContract = require '@lunette-contracts/drops'
local focusContract = require '@lunette-contracts/focus'
local vocabulary = require '@lunette-contracts/vocabulary'
local grab = require '@lunette-plugins/interaction/grab'
local picking = require '@lunette-plugins/interaction/picking'
local input = require '@lunette-plugins/interaction/input'
local nativeFocus = require '@lunette-plugins/interaction/native-focus'
local inspection = require '@lunette-contracts/inspection'
local config = require '@lunette-plugins/interaction/config'

type Service = contracts.Service
type Pointer = contracts.Pointer
type Surface = contracts.Surface
type State = {
  tuning: contracts.Tuning,
  handPosition: vector?,
  grabbed: Surface?,
  grab: grab.GrabState?,
  scaling: grab.Scaling?,
  pointer: Pointer?,
  dead: boolean,
  generation: number,
  withdrawing: boolean,
  seat: lunette.Seat?,
  focusTarget: focusContract.TargetHandle?,
  focusSink: lunette.Sink?,
  focusSeatId: number?,
  hovered: Surface?,
  hoveredSink: lunette.Sink?,
  hitX: number?,
  hitY: number?,
  distance: number?,
  held: { [lunette.PointerButton]: boolean },
  pressed: { [lunette.PointerButton]: boolean },
  blocked: { [lunette.PointerButton]: boolean },
  quarantined: boolean,
  captures: { [lunette.PointerButton]: input.Capture },
  pendingCaptures: { [input.Capture]: { reason: contracts.CancelReason? } },
  pressedSink: { [lunette.PointerButton]: input.NativePress },
  gripped: boolean,
  grabInput: 'grip' | 'trigger',
  pulse: ((contracts.Haptic) -> boolean)?,
}

export type DriveBase = config.DriveBase
export type Drive = config.Drive
export type ConstrainBase = config.ConstrainBase
export type Constrain = config.Constrain
export type Settings = config.Settings
export type Config = config.Config

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

local function unchanged(_surface: Surface, pose: Mat4): Mat4
  return pose
end

local function build(context: plugin.Context, settings: Settings): Service
  local active = true
  local TUNING = settings.tuning
  local pointers: { Pointer } = {}
  local states: { [Pointer]: State } = {}
  local owners: { [Pointer]: contracts.Owner } = {}
  local dropService: dropsContract.Service = context:require(dropsContract.capability)
  local focusService: focusContract.Service = context:require(focusContract.capability)

  local function live(state: State): boolean
    return active and context:active() and not state.dead and not state.withdrawing
  end

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
    dropped = function(target: Surface, pointer: Pointer)
      -- Pending unload forbids acquisition but still permits this terminal notification before cleanup.
      if active then
        dropService:emit(context, { surface = target, pointer = pointer })
      end
    end,
    constrain = function(target: Surface, pose: Mat4): Mat4
      return settings.constrain(target, pose, unchanged)
    end,
    current = function(pointer: Pointer): () -> boolean
      local state = states[pointer]
      local generation = state and state.generation
      return function(): boolean
        return state ~= nil and live(state) and states[pointer] == state and state.generation == generation
      end
    end,
  }

  local function host(state: State): input.Host
    return {
      live = function(): boolean
        return live(state)
      end,
      focus = function(sink)
        if settings.focusOnPress then
          local generation = state.generation
          nativeFocus.give(state, sink, context, focusService, function(): boolean
            return live(state) and state.generation == generation
          end)
        end
      end,
      hoveredByAnother = function(target: Surface): boolean
        for _, other in pairs(states) do
          if other ~= state and not other.dead and other.hovered == target then
            return true
          end
        end
        return false
      end,
    }
  end

  local function endGrab(state: State, pointer: Pointer): boolean
    state.generation += 1
    return carrying.endGrab(pointer)
  end

  local function withdraw(state: State, pointer: Pointer, reason: contracts.CancelReason, revokeFocus: boolean): ()
    state.withdrawing = true
    if reason == 'tracking-loss' then
      state.quarantined = true
    end
    local inverses = input.detach(state, pointer, nil, reason)
    local carried = carrying.detachGrab(state, pointer)
    if carried then
      inverses[#inverses + 1] = carried
    end
    for _, inverse in ipairs(input.clearHover(state, pointer, host(state))) do
      inverses[#inverses + 1] = inverse
    end
    if revokeFocus then
      local focused = nativeFocus.detach(state)
      if focused then
        inverses[#inverses + 1] = focused
      end
    end
    state.gripped = false
    local ok, failure = pcall(input.runInverses, inverses)
    state.withdrawing = false
    if not ok then
      error(failure, 0)
    end
  end

  local function beginGrab(state: State, pointer: Pointer, target: Surface, pose: Mat4?): boolean
    if not live(state) or target.dead or not pose or not target.setPose then
      return false
    end
    local inverses = input.detach(state, pointer, nil, 'grab', false)
    local generation = state.generation
    input.runInverses(inverses)
    if not live(state) or state.generation ~= generation or target.dead then
      return false
    end
    state.grabInput = 'grip'
    return carrying.beginGrab(pointer, target, pose)
  end

  local function defaultDrive(pointer: Pointer, frame: contracts.Input, offered: { read [number]: Surface }): ()
    local state = states[pointer]
    if not state then
      if pointer.dead then
        return
      end
      error('interaction: drive was given a pointer this activation did not make', 2)
    end
    if not live(state) then
      return
    end
    local beforeValidation = state.generation
    input.validate(frame)
    if not live(state) or state.generation ~= beforeValidation then
      return
    end
    state.generation += 1
    local generation = state.generation
    local function current(): boolean
      return live(state) and state.generation == generation
    end
    local surfaces: { Surface } = {}
    for index = 1, #offered do
      surfaces[#surfaces + 1] = offered[index]
    end
    local offeredSet: { [Surface]: boolean } = {}
    for _, surface in ipairs(surfaces) do
      offeredSet[surface] = true
    end
    local sample = input.sample(state, frame.buttons or {})
    input.resolve(state, pointer, surfaces)
    if not current() then
      return
    end
    state.handPosition = frame.pose and vector.pack(frame.pose:getPosition()) or nil
    local gripped, grabbed = frame.grip, state.grabbed
    if grabbed then
      state.gripped = gripped
      local held = if state.grabInput == 'trigger' then sample.held.left == true else gripped
      if grabbed.dead or not held or not offeredSet[grabbed] then
        local releases = input.releases(state, pointer, sample)
        local inverses = {
          function()
            endGrab(state, pointer)
          end,
          function()
            input.runInverses(releases)
          end,
        }
        input.runInverses(inverses)
        return
      elseif state.scaling then
        carrying.scaleWith(pointer, frame.pose)
      else
        carrying.push(pointer, frame.scrollY or 0, frame.dt or 0)
        if current() then
          carrying.dragTo(pointer, frame.pose)
        end
      end
      if current() then
        input.buttons(state, pointer, sample, nil, nil, host(state), false)
      end
      return
    end
    local hit: Surface?, x: number?, y: number?, distance: number?
    local length = frame.direction:length()
    if length > 0 then
      local ray = frame.direction * (1 / length)
      for _, candidate in ipairs(surfaces) do
        if not candidate.dead then
          local cx, cy, cd = candidate:raycast(frame.origin, ray)
          if not current() then
            return
          end
          input.coordinates(cx, cy, cd)
          if
            not candidate.dead
            and cx
            and cy
            and cd
            and cd <= state.tuning.reach
            and (not distance or cd < distance)
          then
            hit, x, y, distance = candidate, cx, cy, cd
          end
        end
      end
    end
    local sink = hit and hit.sink and hit:sink() or nil
    if not current() then
      return
    end
    input.hover(state, pointer, hit, x, y, distance, sink, host(state))
    if not current() then
      return
    end
    local startingGrab = hit and gripped and not state.gripped and hit.grabbable ~= false
    state.gripped = gripped
    local triggerGrab = hit and hit.triggerGrabbable == true and sample.down.left == true
    local grabTarget: Surface? = hit
    if (startingGrab or triggerGrab) and hit and hit.grabTarget then
      grabTarget = hit:grabTarget()
      if not current() then
        return
      end
    end
    if
      (startingGrab or triggerGrab)
      and grabTarget
      and offeredSet[grabTarget]
      and beginGrab(state, pointer, grabTarget, frame.pose)
    then
      state.grabInput = if startingGrab then 'grip' else 'trigger'
      if triggerGrab then
        state.blocked.left = true
      end
      return
    end
    if not current() then
      return
    end
    input.motion(state, pointer, frame, hit, sink, state.tuning.reach, host(state))
    if not current() then
      return
    end
    local dx, dy = picking.scrollDelta {
      x = frame.scrollX or 0,
      y = frame.scrollY or 0,
      dt = frame.dt,
      tuning = state.tuning,
    }
    input.scroll(state, pointer, hit, sink, dx, dy)
    if current() then
      input.buttons(state, pointer, sample, sink, hit, host(state))
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
      pointer = nil,
      dead = false,
      generation = 0,
      withdrawing = false,
      seat = options and options.seat,
      focusTarget = nil,
      focusSink = nil,
      focusSeatId = nil,
      pulse = pulse,
      hovered = nil,
      hoveredSink = nil,
      hitX = nil,
      hitY = nil,
      distance = nil,
      gripped = false,
      grabInput = 'grip',
      held = {},
      pressed = {},
      blocked = {},
      quarantined = false,
      captures = {},
      pendingCaptures = {},
      pressedSink = {},
    }
    local cleanupEffect: plugin.Effect? = nil
    local public: Pointer
    local function destroyRaw(reason: contracts.CancelReason): boolean
      if state.dead then
        return false
      end
      state.dead = true
      local index = table.find(pointers, public)
      if index then
        table.remove(pointers, index)
      end
      states[public], owners[public] = nil, nil
      withdraw(state, public, reason, true)
      return true
    end
    local function destroy(reason: contracts.CancelReason): boolean
      if state.dead then
        return false
      end
      local effect = cleanupEffect
      cleanupEffect = nil
      input.runInverses {
        function()
          destroyRaw(reason)
        end,
        function()
          if effect then
            effect:dispose()
          end
        end,
      }
      return true
    end
    local methods = {
      hover = function(self: Pointer, target: Surface?)
        if live(state) then
          state.generation += 1
          local generation = state.generation
          local sink = target and target.sink and target:sink() or nil
          if live(state) and state.generation == generation then
            input.hover(state, self, target, nil, nil, nil, sink, host(state))
          end
        end
      end,
      focus = function(_self: Pointer, sink: lunette.Sink?)
        if live(state) then
          state.generation += 1
          local generation = state.generation
          nativeFocus.give(state, sink, context, focusService, function(): boolean
            return live(state) and state.generation == generation
          end)
        end
      end,
      setButton = function(self: Pointer, given: contracts.ButtonState)
        local button = given.button or 'left'
        if not BUTTONS[button] then
          error('interaction: setButton presses a pointer button, not ' .. tostring(button), 2)
        end
        if live(state) then
          state.generation += 1
          input.setButton(state, self, given, host(state))
        end
      end,
      cancel = function(self: Pointer, target: Surface, reason: contracts.CancelReason)
        input.cancelReason(reason)
        if live(state) then
          input.runInverses(input.detach(state, self, target, reason))
        end
      end,
      withdraw = function(self: Pointer)
        if live(state) then
          withdraw(state, self, 'tracking-loss', false)
        end
      end,
      destroy = function(_self: Pointer): boolean
        return destroy(if active then 'pointer-destroyed' else 'provider-replaced')
      end,
      beginGrab = function(self: Pointer, target: Surface, pose: Mat4?): boolean
        return beginGrab(state, self, target, pose)
      end,
      scaleWith = function(self: Pointer, pose: Mat4?)
        if live(state) then
          state.generation += 1
          carrying.scaleWith(self, pose)
        end
      end,
      push = function(self: Pointer, given: contracts.Push)
        if live(state) then
          state.generation += 1
          carrying.push(self, given.deflection, given.dt)
        end
      end,
      dragTo = function(self: Pointer, pose: Mat4?)
        if live(state) then
          state.generation += 1
          carrying.dragTo(self, pose)
        end
      end,
      endGrab = function(self: Pointer): boolean
        return if live(state) then endGrab(state, self) else false
      end,
      vibrate = function(_self: Pointer, haptic: contracts.Haptic): boolean
        local send = state.pulse
        return live(state) and send ~= nil and send(haptic) == true
      end,
      update = function(self: Pointer, frame: contracts.Input, surfaces: { read [number]: Surface })
        if live(state) then
          local generation = state.generation
          input.validate(frame)
          if live(state) and state.generation == generation then
            state.generation += 1
            input.observe(state, frame.buttons)
            settings.drive(self, frame, surfaces, defaultDrive)
          end
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
      states[public], owners[public] = state, owner
      return function()
        cleanupEffect = nil
        destroyRaw(if active then 'pointer-destroyed' else 'provider-replaced')
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
      local inverses: { () -> () } = {}
      for _, pointer in ipairs(table.clone(pointers)) do
        inverses[#inverses + 1] = function()
          pointer:destroy()
        end
      end
      input.runInverses(inverses)
    end
  end)

  return {
    inspect = function(_self: Service): inspection.Snapshot
      local result: { inspection.Registration } = {}
      for _, pointer in ipairs(pointers) do
        local state, owner = states[pointer], owners[pointer]
        local pressedButtons = 0
        for _, pressed in pairs(state.pressed) do
          if pressed then
            pressedButtons += 1
          end
        end
        local details: { [string]: string | number | boolean } = {
          hovered = state.hovered ~= nil,
          grabbed = state.grabbed ~= nil,
          gripped = state.gripped,
          pressedButtons = pressedButtons,
        }
        if state.seat then
          details.seatId = state.seat.id
        end
        result[#result + 1] = inspection.registration(
          'pointer',
          'interaction.newPointer',
          owner,
          nil,
          active and context:owns(owner) and not state.dead,
          details
        )
      end
      return inspection.snapshot(
        result,
        { active = active },
        { 'hovered and grabbed surface identities are not retained as inspection ids' }
      )
    end,
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

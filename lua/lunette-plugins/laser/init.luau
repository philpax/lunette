-- Each activation owns its hand registry. Owner effects release pointers and owned seats.
-- See docs/dev/lua-api.md#lasers for the options and hooks.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contracts = require '@lunette-contracts/laser'
local interaction = require '@lunette-contracts/interaction'
local vocabulary = require '@lunette-contracts/vocabulary'
local input = require '@lunette-plugins/laser/input'
local draw = require '@lunette-plugins/laser/draw'
local passState = require '@lunette-plugins/pass-state'
local registry = require '@lunette-plugins/laser/registry'
local inspection = require '@lunette-contracts/inspection'

export type Service = contracts.Service
export type Owner = contracts.Owner
export type Options = contracts.Options
export type Laser = contracts.Laser
export type Hand = contracts.Hand
export type Surface = contracts.Surface
export type Input = contracts.Input

local config = require '@lunette-plugins/laser/config'

export type ReadBase = config.ReadBase
export type ReadInput = config.ReadInput
export type DrawBase = config.DrawBase
export type Draw = config.Draw
export type Mapping = input.Mapping
export type Settings = config.Settings
export type Config = config.Config

local HANDS: { Hand } = { 'left', 'right' }

type ProviderState = registry.State
type MutableLaser = registry.MutableLaser

local function makeLaser(state: ProviderState, settings: Settings, owner: Owner, hand: Hand, options: Options?): Laser
  local given: Options = options or {}
  local device = input.devices[hand]
  if not device then
    error("laser: '" .. tostring(hand) .. "' is not a hand a laser is made for", 2)
  end

  local interactionService: interaction.Service = state.context:require(interaction.capability)
  local cleanupEffect: plugin.Effect? = nil
  local created, acquired = state.context:resource(owner, function(): (MutableLaser, () -> ())
    local seat = given.seat or lunette.newSeat(given.name or ('laser.' .. hand))
    local controller = input.controllers[hand]
    -- Haptics use the controller that supplies this hand's input.
    local function pulse(haptic: interaction.Haptic): boolean
      local headset = lovr.headset
      if not state.active or not headset or not headset.vibrate then
        return false
      end
      return headset.vibrate(controller, haptic.strength, haptic.duration, 0) and true
    end
    local made, pointer = pcall(function()
      return interactionService:newPointer(state.context, { seat = seat, tuning = given.tuning, vibrate = pulse })
    end)
    if not made then
      if not given.seat and not seat.dead then
        seat:destroy()
      end
      error(pointer, 0)
    end
    local frameInput: Input? = nil
    local withdrawn = false
    local target: MutableLaser
    target = {
      owner = owner,
      hand = hand,
      device = device,
      controller = controller,
      seat = seat,
      ownsSeat = given.seat == nil,
      readInput = given.readInput or function(which: Hand): Input?
        return settings.readInput(which, function(asked: Hand): Input?
          local headset = lovr.headset
          if not headset then
            return nil
          end
          return input.fromHeadset(asked, headset, settings.buttons)
        end)
      end,
      pointer = pointer,
      style = if given.style
        then {
          length = given.style.length or settings.style.length,
          color = given.style.color or settings.style.color,
          hoverColor = given.style.hoverColor or settings.style.hoverColor,
          cursorRadius = given.style.cursorRadius or settings.style.cursorRadius,
          hapticStrength = given.style.hapticStrength or settings.style.hapticStrength,
          hapticDuration = given.style.hapticDuration or settings.style.hapticDuration,
        }
        else settings.style,
      input = frameInput,
      dead = false,
      update = function(self: Laser, surfaces: { read [number]: Surface })
        if self.dead or not state.active then
          return
        end
        local frame = self.readInput(self.hand)
        target.input = frame
        if not frame then
          if not withdrawn then
            withdrawn = true
            self.pointer:withdraw()
          end
          return
        end
        withdrawn = false
        local before = self.pointer.hovered
        self.pointer:update(frame, surfaces)
        if self.pointer.hovered ~= before then
          self:vibrate()
        end
      end,
      draw = function(self: Laser, pass: Pass)
        if self.dead or not state.active then
          return
        end
        passState.withRestore(pass, function()
          settings.draw(self, pass, draw.laser)
        end)
      end,
      vibrate = function(self: Laser): boolean
        if self.dead then
          return false
        end
        return pulse { strength = self.style.hapticStrength, duration = self.style.hapticDuration }
      end,
      -- The release runs on the caller's stack, so a failure is attributed to that caller.
      destroy = function(self: Laser): boolean
        if self.dead then
          return false
        end
        local effect = cleanupEffect
        cleanupEffect = nil
        local ok, failure = pcall(registry.destroy, state, target)
        if effect then
          effect:dispose()
        end
        if not ok then
          error(failure, 0)
        end
        return true
      end,
    }
    state.lasers[#state.lasers + 1] = target
    return target, function()
      cleanupEffect = nil
      registry.destroy(state, target)
    end
  end)
  if not created.dead then
    cleanupEffect = acquired
  end
  return created
end

local function build(context: plugin.Context, settings: Settings): Service
  -- The published service is revoked with this activation, so its methods need no liveness guard; lasers
  -- outlive the call that made them and check the activation themselves.
  local state: ProviderState = {
    active = true,
    context = context,
    lasers = {},
  }
  context:effect(function()
    return function()
      state.active = false
      registry.destroyAll(state)
    end
  end)
  local service: Service = {
    inspect = function(_self: Service): inspection.Snapshot
      local result: { inspection.Registration } = {}
      local ownedSeats = 0
      for _, target in ipairs(state.lasers) do
        if target.ownsSeat and not target.seat.dead then
          ownedSeats += 1
        end
        result[#result + 1] = inspection.registration(
          'laser',
          'laser.new',
          target.owner,
          target.hand,
          state.active and context:owns(target.owner) and not target.dead,
          {
            hand = target.hand,
            device = target.device,
            seatId = target.seat.id,
            seatDead = target.seat.dead,
            ownsSeat = target.ownsSeat,
            input = target.input ~= nil,
          }
        )
      end
      return inspection.snapshot(
        result,
        { active = state.active, ownedSeats = ownedSeats },
        { 'input sampling and vibration require callbacks' }
      )
    end,
    HANDS = HANDS,
    STYLE = settings.style,
    new = function(_self: Service, owner: Owner, hand: Hand, options: Options?): Laser
      state.context:checkOwner(owner)
      return makeLaser(state, settings, owner, hand, options)
    end,
    -- A hand has one laser: attach answers the owner's own, makes one for a free hand, and raises for a hand
    -- another owner holds.
    attach = function(_self: Service, owner: Owner, options: Options?): { Laser }
      state.context:checkOwner(owner)
      local held: { [Hand]: MutableLaser } = {}
      for _, target in ipairs(state.lasers) do
        if not target.dead then
          if target.owner ~= owner then
            error("laser: the '" .. target.hand .. "' hand already has a laser another owner holds", 2)
          end
          held[target.hand] = target
        end
      end
      local attached: { Laser } = {}
      for _, hand in ipairs(HANDS) do
        attached[#attached + 1] = held[hand] or makeLaser(state, settings, owner, hand, options)
      end
      return attached
    end,
    forHand = function(_self: Service, hand: Hand): Laser?
      for _, target in ipairs(registry.live(state)) do
        if target.hand == hand then
          return target
        end
      end
      return nil
    end,
    all = function(_self: Service): { Laser }
      return registry.live(state)
    end,
    update = function(_self: Service, surfaces: { read [number]: Surface }): ()
      registry.update(state, surfaces)
    end,
    draw = function(_self: Service, pass: Pass): ()
      registry.draw(state, pass)
    end,
  }
  return service
end

local POINTER_BUTTONS: { [string]: boolean } = {}
for _, button in ipairs(vocabulary.POINTER_BUTTONS) do
  POINTER_BUTTONS[button] = true
end

local CONTROLS: { [string]: boolean } = {}
for _, control in ipairs(input.CONTROLS) do
  CONTROLS[control] = true
end

-- The mapping list replaces defaults, so validation checks every supplied entry.
local function validate(settings: Settings, name: string): ()
  for index = 1, #settings.buttons do
    local mapping = settings.buttons[index]
    local where = string.format('plugin %s: option buttons[%d]', name, index)
    if type(mapping) ~= 'table' then
      error(where .. ' is a table of control and button, not a ' .. type(mapping), 0)
    end
    for key, _ in mapping :: { [unknown]: unknown } do
      if key ~= 'control' and key ~= 'button' then
        error(where .. ' has an unknown field ' .. tostring(key) .. '; the fields are control and button', 0)
      end
    end
    if not CONTROLS[mapping.control] then
      error(where .. '.control is a controller button, not ' .. tostring(mapping.control), 0)
    end
    if not POINTER_BUTTONS[mapping.button] then
      error(where .. '.button is a pointer button, not ' .. tostring(mapping.button), 0)
    end
  end
end

return plugin.provider<<Config, Settings, Service>> {
  name = 'laser',
  capability = contracts.capability,
  requires = { interaction = interaction.capability },
  schema = config,
  validate = validate,
  build = build,
}

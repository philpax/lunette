-- The LASER provider. Each activation owns an independent two-hand registry.
-- Native headset reads are isolated from the pointer and drawing logic, and every
-- acquired pointer or seat is released through the caller's owner effect.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contracts = require '@lunette-contracts/laser'
local interaction = require '@lunette-contracts/interaction'
local input = require '@lunette-plugins/laser/input'
local draw = require '@lunette-plugins/laser/draw'
local registry = require '@lunette-plugins/laser/registry'

export type Service = contracts.Service
export type Owner = contracts.Owner
export type Options = contracts.Options
export type Laser = contracts.Laser
export type Hand = contracts.Hand
export type Surface = contracts.Surface
export type Input = contracts.Input

local STYLE: contracts.Style = {
  length = 1.5,
  color = { 0.55, 0.7, 1, 0.5 },
  hoverColor = { 0.75, 0.9, 1, 0.9 },
  cursorRadius = 0.006,
  hapticStrength = 0.2,
  hapticDuration = 0.01,
}

local HANDS: { Hand } = { 'left', 'right' }

type ProviderState = registry.State
type MutableLaser = registry.MutableLaser

type MutableService = {
  HANDS: { Hand },
  DEVICES: { [string]: contracts.Device },
  CONTROLLERS: { [string]: contracts.Device },
  STYLE: contracts.Style,
  new: (Service, Owner, Hand, Options?) -> Laser,
  attach: (Service, Owner, Options?) -> { Laser },
  forHand: (Service, Hand) -> Laser?,
  all: (Service) -> { Laser },
  update: (Service, { Surface }) -> (),
  draw: (Service, Pass) -> (),
  headsetInput: (Service, Hand) -> Input?,
}

local states: { [Service]: ProviderState } = {}

local function current(service: Service): ProviderState
  return registry.stateFor(states, service)
end

local function headsetInput(service: Service, hand: Hand): Input?
  current(service)
  local headset = lovr.headset
  if not headset then
    return nil
  end
  return input.fromHeadset(hand, headset)
end

local function makeLaser(state: ProviderState, owner: Owner, hand: Hand, options: Options?): Laser
  local settings: Options = options or {}
  local device = input.devices[hand]
  if not device then
    error("laser: '" .. tostring(hand) .. "' is not a hand a laser is made for", 2)
  end

  local interactionService: interaction.Service = state.context:require(interaction.capability)
  local created: MutableLaser?
  local cleanupEffect: plugin.Effect? = nil
  local acquired = owner:effect(function()
    state.context:checkOwner(owner)
    local seat = settings.seat or lunette.newSeat(settings.name or ('laser.' .. hand))
    local pointer = interactionService:newPointer(state.context, { seat = seat, tuning = settings.tuning })
    local frameInput: Input? = nil
    local target: MutableLaser
    target = {
      hand = hand,
      device = device,
      controller = input.controllers[hand],
      seat = seat,
      ownsSeat = settings.seat == nil,
      readInput = settings.readInput or function(which: Hand): Input?
        return headsetInput(state.service, which)
      end,
      pointer = pointer,
      style = settings.style or state.service.STYLE,
      input = frameInput,
      dead = false,
      update = function(self: Laser, surfaces: { Surface })
        if self.dead or not state.active then
          return
        end
        local frame = self.readInput(self.hand)
        target.input = frame
        if not frame then
          self.pointer:withdraw()
          return
        end
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
        draw.laser(self, pass)
      end,
      vibrate = function(self: Laser): boolean
        if self.dead or not state.active then
          return false
        end
        local headset = lovr.headset
        if not headset or not headset.vibrate then
          return false
        end
        return headset.vibrate(self.controller, self.style.hapticStrength, self.style.hapticDuration, 0) and true
      end,
      destroy = function(self: Laser): boolean
        if self.dead then
          return false
        end
        local effect = cleanupEffect
        if effect then
          effect:dispose()
          return true
        end
        return registry.destroy(state, target)
      end,
    }
    created = target
    state.lasers[#state.lasers + 1] = target
    local nativeCleanup = state.context:effect(function()
      return function()
        registry.destroy(state, target)
        created = nil
      end
    end)
    return function()
      cleanupEffect = nil
      nativeCleanup:dispose()
    end
  end)

  if not created then
    error 'laser: owner effect did not acquire a laser'
  end
  if not created.dead then
    cleanupEffect = acquired
  end
  return created
end

local function initialize(context: plugin.Context): Service
  local service: Service
  local implementation: MutableService = {
    HANDS = HANDS,
    DEVICES = input.devices,
    CONTROLLERS = input.controllers,
    STYLE = STYLE,
    new = function(_self: Service, owner: Owner, hand: Hand, options: Options?): Laser
      local state = current(service)
      state.context:checkOwner(owner)
      return makeLaser(state, owner, hand, options)
    end,
    attach = function(_self: Service, owner: Owner, options: Options?): { Laser }
      local state = current(service)
      state.context:checkOwner(owner)
      local attached: { Laser } = {}
      for _, hand in ipairs(HANDS) do
        attached[#attached + 1] = service:forHand(hand) or service:new(owner, hand, options)
      end
      return attached
    end,
    forHand = function(_self: Service, hand: Hand): Laser?
      local state = current(service)
      for _, target in ipairs(registry.live(state)) do
        if target.hand == hand then
          return target
        end
      end
      return nil
    end,
    all = function(_self: Service): { Laser }
      return registry.live(current(service))
    end,
    update = function(_self: Service, surfaces: { Surface }): ()
      registry.update(current(service), surfaces)
    end,
    draw = function(_self: Service, pass: Pass): ()
      registry.draw(current(service), pass)
    end,
    headsetInput = function(_self: Service, hand: Hand): Input?
      return headsetInput(service, hand)
    end,
  }
  service = implementation

  local state: ProviderState = {
    active = true,
    context = context,
    service = service,
    lasers = {},
  }
  states[service] = state
  context:effect(function()
    return function()
      state.active = false
      registry.destroyAll(state)
      states[service] = nil
    end
  end)
  return service
end

local provided = { laser = contracts.capability }

return plugin.define(
  function(config: {}): {}
    return config
  end,
  { interaction = interaction.capability },
  provided,
  function(context: plugin.Context, _config: {}, publish: plugin.Publisher)
    publish:provide(contracts.capability, initialize(context))
  end
)

-- The LASER provider. Each activation owns an independent two-hand registry.
-- Native headset reads are isolated from the pointer and drawing logic, and every
-- acquired pointer or seat is released through the caller's owner effect, so a
-- release that fails is the caller's failure rather than this provider's.
--
-- `style` sets the default beam length, colours, cursor size, and hover haptic
-- that a laser's own options override.

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

-- The resolved options. Each activation receives its own frozen copy, so no
-- consumer can restyle another's lasers.
export type Settings = {
  read style: contracts.Style,
}

-- What a configuration gives: every option optional.
export type Config = {
  read style: {
    read length: number?,
    read color: contracts.Color?,
    read hoverColor: contracts.Color?,
    read cursorRadius: number?,
    read hapticStrength: number?,
    read hapticDuration: number?,
  }?,
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

local function headsetInput(hand: Hand): Input?
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
    local controller = input.controllers[hand]
    -- The pointer's haptics reach this hand's controller, so whatever the
    -- pointer presses can answer with a pulse on the hand that pressed it.
    local function pulse(haptic: interaction.Haptic): boolean
      local headset = lovr.headset
      if not state.active or not headset or not headset.vibrate then
        return false
      end
      return headset.vibrate(controller, haptic.strength, haptic.duration, 0) and true
    end
    local made, pointer = pcall(function()
      return interactionService:newPointer(state.context, { seat = seat, tuning = settings.tuning, vibrate = pulse })
    end)
    if not made then
      if not settings.seat and not seat.dead then
        seat:destroy()
      end
      error(pointer, 0)
    end
    local frameInput: Input? = nil
    local target: MutableLaser
    target = {
      owner = owner,
      hand = hand,
      device = device,
      controller = controller,
      seat = seat,
      ownsSeat = settings.seat == nil,
      readInput = settings.readInput or function(which: Hand): Input?
        return headsetInput(which)
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
        if self.dead then
          return false
        end
        return pulse { strength = self.style.hapticStrength, duration = self.style.hapticDuration }
      end,
      -- The release runs here, on the caller's stack, so its failure is the
      -- caller's; the owner's effect is then disposed with nothing left to do.
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
    created = target
    state.lasers[#state.lasers + 1] = target
    return function()
      cleanupEffect = nil
      registry.destroy(state, target)
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

local function build(context: plugin.Context, settings: Settings): Service
  local service: Service
  -- The published service is revoked with this activation, so its methods
  -- need no liveness guard. Lasers outlive the call that made them and check
  -- the activation themselves.
  local state: ProviderState
  local implementation: MutableService = {
    HANDS = HANDS,
    DEVICES = input.devices,
    CONTROLLERS = input.controllers,
    STYLE = settings.style,
    new = function(_self: Service, owner: Owner, hand: Hand, options: Options?): Laser
      state.context:checkOwner(owner)
      return makeLaser(state, owner, hand, options)
    end,
    -- A hand has one laser. attach answers the owner's own laser for a hand
    -- it already holds, makes one for a free hand, and raises for a hand
    -- another owner holds rather than handing that owner's laser over.
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
        attached[#attached + 1] = held[hand] or makeLaser(state, owner, hand, options)
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
    update = function(_self: Service, surfaces: { Surface }): ()
      registry.update(state, surfaces)
    end,
    draw = function(_self: Service, pass: Pass): ()
      registry.draw(state, pass)
    end,
    headsetInput = function(_self: Service, hand: Hand): Input?
      return headsetInput(hand)
    end,
  }
  service = implementation

  local created: ProviderState = {
    active = true,
    context = context,
    service = service,
    lasers = {},
  }
  state = created
  context:effect(function()
    return function()
      state.active = false
      registry.destroyAll(state)
    end
  end)
  return service
end

return plugin.provider<<Config, Settings, Service>> {
  name = 'laser',
  capability = contracts.capability,
  requires = { interaction = interaction.capability },
  defaults = {
    style = {
      length = 1.5,
      color = { 0.55, 0.7, 1, 0.5 },
      hoverColor = { 0.75, 0.9, 1, 0.9 },
      cursorRadius = 0.006,
      hapticStrength = 0.2,
      hapticDuration = 0.01,
    },
  },
  build = build,
}

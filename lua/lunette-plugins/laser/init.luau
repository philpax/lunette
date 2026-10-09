-- Each activation owns its hand registry. Owner effects release pointers and owned seats.
-- See docs/dev/lua-api.md#lasers for the options and hooks.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contracts = require '@lunette-contracts/laser'
local interaction = require '@lunette-contracts/interaction'
local input = require '@lunette-plugins/laser/input'
local draw = require '@lunette-plugins/laser/draw'
local aim = require '@lunette-plugins/laser/aim'
local triggerLock = require '@lunette-plugins/laser/trigger-lock'
local passState = require '@lunette-plugins/pass-state'
local registry = require '@lunette-plugins/laser/registry'
local inspection = require '@lunette-contracts/inspection'
local theme = require '@lunette-contracts/theme'
local style = require '@lunette-plugins/laser/style'

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
  local styleOverrides = style.overrides.parse(given.style or {}, 'laser: style')
  state.refreshStyle()
  local aimSettings = aim.resolve(given.aim, settings.aim)
  local lockSettings = triggerLock.resolve(given.triggerLock, settings.triggerLock)
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
    local aimState: aim.State? = nil
    local previousRaw: triggerLock.RawAim? = nil
    local lockState: triggerLock.State = triggerLock.ready()
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
      style = style.resolve(state.themes:current().theme, settings.style, styleOverrides),
      styleOverrides = styleOverrides,
      input = frameInput,
      dead = false,
      update = function(self: Laser, surfaces: { read [number]: Surface })
        if self.dead or not state.active then
          return
        end
        state.refreshStyle()
        local sampled = self.readInput(self.hand)
        if not sampled then
          aimState = nil
          previousRaw = nil
          lockState = triggerLock.ready()
          target.input = nil
          if not withdrawn then
            withdrawn = true
            self.pointer:withdraw()
          end
          return
        end
        local filtered, nextAim = aim.update(aimState, sampled, aimSettings)
        aimState = nextAim
        local frame, nextLock = triggerLock.update(lockState, {
          raw = sampled,
          filtered = filtered,
          previous = target.input,
          previousRaw = previousRaw,
          hovered = self.pointer.hovered,
          grabbed = self.pointer.grabbed,
          surfaces = surfaces,
          resetAfter = aimSettings.resetAfter,
        }, lockSettings)
        lockState = nextLock
        previousRaw = { origin = sampled.origin, direction = sampled.direction }
        target.input = frame
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
        state.refreshStyle()
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
  local themes: theme.Service = context:require(theme.capability)
  local revision = -1
  local publishStyle: (contracts.Style) -> () = function(_style: contracts.Style): () end
  local state: ProviderState
  local function refreshStyle(): ()
    if not state.active or not context:active() then
      return
    end
    local snapshot = themes:current()
    if revision == snapshot.revision then
      return
    end
    local resolved = style.resolve(snapshot.theme, settings.style)
    for _, target in ipairs(state.lasers) do
      target.style = style.resolve(snapshot.theme, settings.style, target.styleOverrides)
    end
    publishStyle(resolved)
    revision = snapshot.revision
  end
  state = {
    active = true,
    context = context,
    lasers = {},
    themes = themes,
    refreshStyle = refreshStyle,
  }
  context:effect(function()
    return function()
      state.active = false
      registry.destroyAll(state)
    end
  end)
  local service = {
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
    STYLE = style.resolve(themes:current().theme, settings.style),
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
  publishStyle = function(resolved: contracts.Style): ()
    service.STYLE = resolved
  end
  themes:onChanged(context, function(_snapshot: theme.Snapshot): ()
    refreshStyle()
  end)
  refreshStyle()
  return service
end

return plugin.provider<<Config, Settings, Service>> {
  name = 'laser',
  capability = contracts.capability,
  requires = { interaction = interaction.capability, theme = theme.capability },
  schema = config,
  build = build,
}

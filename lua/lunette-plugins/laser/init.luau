-- Each activation owns its hand registry. Owner effects release pointers and owned seats.
-- See lua/lunette-plugins/laser/README.md for the options and hooks.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contracts = require '@lunette-contracts/laser'
local interaction = require '@lunette-contracts/interaction'
local input = require '@lunette-plugins/laser/input'
local draw = require '@lunette-plugins/laser/draw'
local aim = require '@lunette-plugins/laser/aim'
local triggerLock = require '@lunette-plugins/laser/trigger-lock'
local passState = require '@lunette-plugins/graphics/pass-state'
local inspection = require '@lunette-contracts/inspection'
local theme = require '@lunette-contracts/theme'
local style = require '@lunette-plugins/laser/style'
local dragIcon = require '@lunette-plugins/laser/drag-icon'
local clientPixels = require '@lunette-plugins/graphics/client-pixels'

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
export type Beam = config.Beam

local HANDS: { Hand } = { 'left', 'right' }

type MutableLaser = {
  owner: Owner,
  hand: Hand,
  device: input.Device,
  controller: input.Device,
  seat: lunette.Seat,
  ownsSeat: boolean,
  readInput: (Hand) -> Input?,
  pointer: interaction.Pointer,
  style: style.Style,
  read styleOverrides: contracts.StyleOverride,
  input: Input?,
  icon: dragIcon.State,
  iconShaders: clientPixels.Shaders,
  dead: boolean,
  update: (Beam, { read [number]: Surface }) -> (),
  draw: (Beam, Pass) -> (),
  vibrate: (Beam) -> boolean,
  destroy: (Beam) -> boolean,
}

type ProviderState = {
  active: boolean,
  read context: plugin.Context,
  lasers: { MutableLaser },
  read iconShaders: clientPixels.Shaders,
  read themes: theme.Service,
  read refreshStyle: () -> (),
}

-- Pointer release errors are raised after the owned seat is released.
local function destroy(state: ProviderState, target: MutableLaser): ()
  if target.dead then
    return
  end
  target.dead = true
  dragIcon.release(target.icon)
  local index = table.find(state.lasers, target)
  if index then
    table.remove(state.lasers, index)
  end
  local released, failure = pcall(function()
    target.pointer:destroy()
  end)
  if target.ownsSeat and not target.seat.dead then
    target.seat:destroy()
  end
  if not released then
    error(failure, 0)
  end
end

local function live(state: ProviderState): { MutableLaser }
  local found: { MutableLaser } = {}
  for _, target in ipairs(state.lasers) do
    if not target.dead then
      found[#found + 1] = target
    end
  end
  return found
end

local function makeLaser(
  state: ProviderState,
  settings: Settings,
  owner: Owner,
  hand: Hand,
  options: Options?
): MutableLaser
  local given: Options = options or {}
  local styleOverrides = style.overrides.parse(given.style or {}, 'laser style')
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
    local seat = given.seat or lunette.newSeat { name = given.name or ('laser.' .. hand) }
    local controller = input.controllers[hand]
    -- Haptics use the controller that supplies this hand's input.
    local function pulse(haptic: interaction.Haptic): boolean
      local headset = lovr.headset
      if not state.active or not headset or not headset.vibrate then
        return false
      end
      return headset.vibrate(controller, haptic.strength, haptic.duration, 0) and true
    end
    local made, pointer = pcall(function(): interaction.Pointer
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
      icon = dragIcon.new(),
      iconShaders = state.iconShaders,
      dead = false,
      update = function(self: Beam, surfaces: { read [number]: Surface })
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
        dragIcon.observe(target.icon, self.pointer.hovered)
        if self.pointer.hovered ~= before then
          self:vibrate()
        end
      end,
      draw = function(self: Beam, pass: Pass)
        if self.dead or not state.active then
          return
        end
        state.refreshStyle()
        passState.withRestore(pass, function()
          settings.draw(self, pass, draw.laser)
        end)
      end,
      vibrate = function(self: Beam): boolean
        if self.dead then
          return false
        end
        return pulse { strength = self.style.hapticStrength, duration = self.style.hapticDuration }
      end,
      -- The release runs on the caller's stack, so a failure is attributed to that caller.
      destroy = function(self: Beam): boolean
        if self.dead then
          return false
        end
        local effect = cleanupEffect
        cleanupEffect = nil
        local ok, failure = pcall(destroy, state, target)
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
      destroy(state, target)
    end
  end)
  if not created.dead then
    cleanupEffect = acquired
  end
  return created
end

local function build(context: plugin.Context, settings: Settings): Service
  -- The published service is revoked with this activation, so its methods need no liveness guard. Lasers
  -- outlive the call that made them, so they check the activation themselves.
  local themes: theme.Service = context:require(theme.capability)
  local revision = -1
  local state: ProviderState
  local function refreshStyle(): ()
    if not state.active or not context:active() then
      return
    end
    local snapshot = themes:current()
    if revision == snapshot.revision then
      return
    end
    for _, target in ipairs(state.lasers) do
      target.style = style.resolve(snapshot.theme, settings.style, target.styleOverrides)
    end
    revision = snapshot.revision
  end
  state = {
    active = true,
    context = context,
    lasers = {},
    iconShaders = clientPixels.shaders(context, function(): boolean
      return state.active
    end),
    themes = themes,
    refreshStyle = refreshStyle,
  }
  context:effect(function(): () -> ()
    return function()
      state.active = false
      for _, target in ipairs(live(state)) do
        target:destroy()
      end
      state.lasers = {}
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
          'laser.attach',
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
    update = function(_self: Service, surfaces: { read [number]: Surface }): ()
      for _, target in ipairs(live(state)) do
        target:update(surfaces)
      end
    end,
    draw = function(_self: Service, pass: Pass): ()
      for _, target in ipairs(live(state)) do
        target:draw(pass)
      end
    end,
  }
  themes:onChanged(context, {
    run = function(_snapshot: theme.Snapshot): ()
      refreshStyle()
    end,
  })
  refreshStyle()
  return service
end

return plugin.provider<<Config, Settings, Service>> {
  name = 'laser',
  capability = contracts.capability,
  requires = { interaction.capability, theme.capability },
  schema = config.schema,
  build = build,
}

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contracts = require '@lunette-contracts/laser'
local interaction = require '@lunette-contracts/interaction'

local registry = {}

export type Service = contracts.Service
export type Laser = contracts.Laser
export type Hand = contracts.Hand

export type MutableLaser = {
  owner: contracts.Owner,
  hand: Hand,
  device: contracts.Device,
  controller: contracts.Device,
  seat: lunette.Seat,
  ownsSeat: boolean,
  readInput: (Hand) -> contracts.Input?,
  pointer: interaction.Pointer,
  style: contracts.Style,
  input: contracts.Input?,
  dead: boolean,
  update: (Laser, { contracts.Surface }) -> (),
  draw: (Laser, Pass) -> (),
  vibrate: (Laser) -> boolean,
  destroy: (Laser) -> boolean,
}

export type State = {
  active: boolean,
  read context: plugin.Context,
  lasers: { MutableLaser },
}

local function remove(state: State, target: Laser)
  for index, existing in ipairs(state.lasers) do
    if existing == target then
      table.remove(state.lasers, index)
      return
    end
  end
end

-- Pointer release errors are raised after the owned seat is released.
function registry.destroy(state: State, target: MutableLaser): boolean
  if target.dead then
    return false
  end

  target.dead = true
  remove(state, target)
  local released, failure = pcall(function()
    target.pointer:destroy()
  end)
  if target.ownsSeat and not target.seat.dead then
    target.seat:destroy()
  end
  if not released then
    error(failure, 0)
  end
  return true
end

function registry.live(state: State): { Laser }
  local live: { Laser } = {}
  for _, target in ipairs(state.lasers) do
    if not target.dead then
      live[#live + 1] = target
    end
  end
  return live
end

function registry.destroyAll(state: State)
  for _, target in ipairs(registry.live(state)) do
    target:destroy()
  end
  state.lasers = {}
end

function registry.update(state: State, surfaces: { contracts.Surface })
  for _, target in ipairs(registry.live(state)) do
    target:update(surfaces)
  end
end

function registry.draw(state: State, pass: Pass)
  for _, target in ipairs(registry.live(state)) do
    target:draw(pass)
  end
end

return registry

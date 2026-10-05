-- Focus grants last until their effect is disposed or the owner unloads. The most recent grant takes precedence; updating the same owner's seat moves its existing grant.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'

local focus = {}

export type Owner = owner.Owner

export type Focus = {
  read seat: lunette.Seat?,
  read sink: lunette.Sink?,
}

export type Listener = {
  read run: (Focus) -> (),
}

local inspection = require '@lunette-contracts/inspection'

export type Service = {
  read inspect: (Service) -> inspection.Snapshot,
  read focused: (Service) -> (lunette.Seat?, lunette.Sink?),
  read setFocus: (Service, Owner, Focus) -> plugin.Effect,
  read onChanged: (Service, Owner, Listener) -> plugin.Effect,
}

export type Capability = plugin.Capability<Service>

focus.capability = plugin.capability<<Service>> { name = 'lunette/focus', schema = 1 }

return focus

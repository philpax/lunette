-- The keyboard focus service contract.
--
-- Focus is which seat's keyboard goes to which sink. It is held, not merely
-- set: setFocus grants focus for an owner, and the grant lasts until the
-- returned effect is disposed or the owner unloads. When a grant ends, the
-- seat it focused is withdrawn natively and focused stops answering it, unless
-- a later grant has taken that seat.
--
-- An owner holds one grant per seat. A later setFocus by the same owner for
-- the same seat moves that grant and answers the same effect, so an owner that
-- follows gaze or hover does not accumulate effects. A nil sink withdraws the
-- owner's grant for the seat without ending it. focused answers the seat and
-- sink of the most recent grant still standing, or nothing.
--
-- onChanged listeners hear the pair focused answers whenever it changes. Each
-- runs under its own protected call, and its error is reported through
-- lunette.reportError without undoing the change.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'

local focus = {}

export type Owner = owner.Owner

-- What setFocus gives a grant to: a seat's keyboard and the sink that
-- receives it, and what an onChanged listener hears.
export type Focus = {
  read seat: lunette.Seat?,
  read sink: lunette.Sink?,
}

export type Listener = {
  read run: (Focus) -> (),
}

export type Service = {
  read focused: (Service) -> (lunette.Seat?, lunette.Sink?),
  read setFocus: (Service, Owner, Focus) -> plugin.Effect,
  read onChanged: (Service, Owner, Listener) -> plugin.Effect,
}

export type Capability = plugin.Capability<Service>

focus.capability = plugin.capability<<Service>> { name = 'lunette/focus', schema = 1 }

return focus

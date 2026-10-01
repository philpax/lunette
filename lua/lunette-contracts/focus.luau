-- The keyboard focus service contract. Focus is held: an owner's grant for a seat lasts until its effect is
-- disposed or the owner unloads, and the most recent standing grant decides. A later setFocus by the same
-- owner and seat moves the grant and answers the same effect. See docs/dev/lua-api.md#pointers-and-interaction.

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

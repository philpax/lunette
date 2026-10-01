-- The tag service contract.
--
-- Tag creation registers caller-owned state even though it acquires no native
-- handle. Membership borrows panels rather than owning their lifetimes.
--
-- Every change to a tag names the owner making it and lasts as long as that
-- owner. add holds a membership for the owner; the panel is a member while any
-- owner holds it. remove drops the owner's own hold, and the tag's owner may
-- drop every hold. setSelected and only set the owner's selection override; the
-- most recent override that is still live decides a tag's selection, and a tag
-- with none has the selection it was created with.

local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'
local surface = require '@lunette-contracts/surface'

local tags = {}

export type Panel = surface.Surface & {
  read setPose: (surface.Surface, Mat4) -> (),
}

export type Options = {
  read index: number?,
  read selected: boolean?,
  read layout: (({ Panel }) -> ())?,
}

export type Owner = owner.Owner

-- What setSelected sets: the owner's selection override.
export type Selection = {
  read selected: boolean,
}

export type Tag = {
  read name: string,
  read index: number,
  read selected: boolean,
  read layout: (({ Panel }) -> ())?,
  read dead: boolean,
  read members: { Panel },
  read add: (Tag, Owner, Panel) -> boolean,
  read remove: (Tag, Owner, Panel) -> boolean,
  read has: (Tag, Panel) -> boolean,
  read panels: (Tag) -> { Panel },
  read setSelected: (Tag, Owner, Selection) -> boolean,
  read apply: (Tag) -> boolean,
  read destroy: (Tag) -> boolean,
}

export type Target = Tag | { Tag } | { Panel }

export type Service = {
  read new: (Service, Owner, string, Options?) -> Tag,
  read all: (Service) -> { Tag },
  read find: (Service, string) -> Tag?,
  read current: (Service) -> { Tag },
  read only: (Service, Owner, Tag) -> (),
  read isTag: (Service, unknown) -> boolean,
  read panelsOf: (Service, Target) -> { Panel },
}

export type Capability = plugin.Capability<Service>

local capability = plugin.capability<<Service>> { name = 'lunette/tags', schema = 1 }

tags.capability = capability

return tags

-- The tag service contract: owner-scoped groups of borrowed panels. A tag is owned through `new` or shared
-- through `hold`, and every membership, exclusion, selection, and layout change lasts as long as the owner
-- that made it. A tag's layout is a name the layouts broker resolves. See docs/dev/lua-api.md#tags.

local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'
local surface = require '@lunette-contracts/surface'

local tags = {}

export type Panel = surface.Movable

export type Options = {
  read index: number?,
  read selected: boolean?,
  read layout: string?,
}

-- What hold takes: the tag's name, and the options it is made with when the
-- call makes it.
export type Hold = {
  read name: string,
  read index: number?,
  read selected: boolean?,
  read layout: string?,
}

export type Owner = owner.Owner

-- What setSelected sets: the owner's selection override.
export type Selection = {
  read selected: boolean,
}

-- What setLayout sets: the owner's layout override. A layout of nil is an
-- override that says the tag has none.
export type LayoutChoice = {
  read layout: string?,
}

-- What exclude takes: the panel the owner keeps out of the tag.
export type Exclusion = {
  read panel: Panel,
}

export type Tag = {
  read name: string,
  read index: number,
  read selected: boolean,
  read layout: string?,
  read dead: boolean,
  read members: { Panel },
  read add: (Tag, Owner, Panel) -> boolean,
  read remove: (Tag, Owner, Panel) -> boolean,
  read exclude: (Tag, Owner, Exclusion) -> plugin.Effect,
  read has: (Tag, Panel) -> boolean,
  read panels: (Tag) -> { Panel },
  read setSelected: (Tag, Owner, Selection) -> boolean,
  read setLayout: (Tag, Owner, LayoutChoice) -> boolean,
  read destroy: (Tag, Owner) -> boolean,
}

export type Target = Tag | { Tag } | { Panel }

-- What changed: a tag being made or ending, its selection, its layout, or
-- its members.
export type ChangeKind = 'created' | 'destroyed' | 'selection' | 'layout' | 'membership'

export type Change = {
  read tag: Tag,
  read kind: ChangeKind,
}

-- What onChanged takes: the tag to hear, every tag when nil, and what runs.
export type ChangeListener = {
  read tag: Tag?,
  read run: (Change) -> (),
}

export type Service = {
  read new: (Service, Owner, string, Options?) -> Tag,
  read hold: (Service, Owner, Hold) -> (Tag, plugin.Effect),
  read all: (Service) -> { Tag },
  read find: (Service, string) -> Tag?,
  read current: (Service) -> { Tag },
  read only: (Service, Owner, Tag) -> (),
  read isTag: (Service, unknown) -> boolean,
  read panelsOf: (Service, Target) -> { Panel },
  read onChanged: (Service, Owner, ChangeListener) -> plugin.Effect,
}

export type Capability = plugin.Capability<Service>

local capability = plugin.capability<<Service>> { name = 'lunette/tags', schema = 1 }

tags.capability = capability

return tags

-- Tags borrow panels. Membership, exclusion, selection, and layout changes last for the owning activation.

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

export type Hold = {
  read name: string,
  read index: number?,
  read selected: boolean?,
  read layout: string?,
}

export type Owner = owner.Owner

export type Selection = {
  read selected: boolean,
}

-- A nil layout explicitly clears the owner's layout override.
export type LayoutChoice = {
  read layout: string?,
}

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

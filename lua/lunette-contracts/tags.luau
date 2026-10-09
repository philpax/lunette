-- Tags borrow panels. Membership, exclusion, and selection changes last for the owning activation.

local plugin = require '@lunette-plugin'
local vocabulary = require '@lunette-contracts/vocabulary'

local tags = {}

export type Panel = vocabulary.Movable

export type Hold = {
  read name: string,
  read index: number?,
}

export type Owner = plugin.Owner

export type Tag = {
  read name: string,
  read index: number,
  read selected: boolean,
  read dead: boolean,
  read add: (Tag, Owner, Panel) -> boolean,
  read remove: (Tag, Owner, Panel) -> boolean,
  read exclude: (Tag, Owner, Panel) -> plugin.Effect,
  read has: (Tag, Panel) -> boolean,
  read panels: (Tag) -> { Panel },
  -- The most recent live override decides selection. Disposing the effect ends this owner's override.
  read setSelected: (Tag, Owner, boolean) -> plugin.Effect,
}

export type ChangeKind = 'created' | 'destroyed' | 'selection' | 'membership'

export type Change = {
  read tag: Tag,
  read kind: ChangeKind,
}

-- What onChanged takes: the tag to hear, every tag when nil, and what runs.
export type ChangeListener = {
  read tag: Tag?,
  read run: (Change) -> (),
}

local inspection = require '@lunette-contracts/inspection'

export type Service = {
  read inspect: (Service) -> inspection.Snapshot,
  read hold: (Service, Owner, Hold) -> (Tag, plugin.Effect),
  read all: (Service) -> { Tag },
  read find: (Service, string) -> Tag?,
  read onChanged: (Service, Owner, ChangeListener) -> plugin.Effect,
}

export type Capability = plugin.Capability<Service>

local capability = plugin.capability<<Service>> { name = 'lunette/tags', version = 1 }

tags.capability = capability

return tags

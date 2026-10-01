-- The tag service contract.
--
-- Tag creation registers caller-owned state even though it acquires no native
-- handle. Membership borrows panels rather than owning their lifetimes.
--
-- A tag is made in one of two ways. new makes a tag that belongs to its
-- caller: the name is the caller's alone, a second new of it raises, and the
-- tag ends when that owner unloads. hold answers the tag of that name,
-- making it when there is none, and holds it for the caller: a tag hold made
-- lasts while any owner holds it, so several plugins that need one tag need
-- not agree on which of them makes it, or in which order they start. Holding
-- a tag that new made borrows it and does not extend its life. The options
-- of new and hold apply only when the call makes the tag.
--
-- Every change to a tag names the owner making it and lasts as long as that
-- owner. add holds a membership for the owner, and exclude holds an
-- exclusion: a panel is a member while any owner holds its membership and no
-- owner holds an exclusion of it, so a plugin moves a window that another
-- plugin added out of a tag by excluding it. remove drops the owner's own
-- hold, and the owner of a tag that new made may drop every hold.
-- setSelected and setLayout set the owner's override; the most recent
-- override that is still live decides a tag's selection or layout, and a tag
-- with none has the value it was made with.
--
-- A tag's layout is the name of a layout in the lunette/layouts broker, or
-- nil. The tags service does not resolve it: whatever arranges a tag looks
-- the name up, so a tag depends on no layout.
--
-- onChanged hears every tag, or only the tag it names. A change is announced
-- after it is made: a tag being made or ending, its selection or layout
-- changing, and its members changing because an owner added, removed, or
-- excluded one. A panel that dies leaves its tags without an announcement;
-- the panels contract's onRemoved announces it. A listener is owner-scoped,
-- runs under its own protected call, and its error is reported through
-- lunette.reportError.

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
  read destroy: (Tag) -> boolean,
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

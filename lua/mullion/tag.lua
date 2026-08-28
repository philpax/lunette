-- Tags: named groups of panels, and which of them the user is looking at.
--
-- docs/stdlib.md's tier 3, the part that determines what is shown. A tag has a
-- name, an index, a selected flag, and a layout attached, and a panel belongs
-- to a set of tags, not to one workspace.
--
-- The model uses two sets: membership and selection. "Show this panel on two
-- tags" is expressible without a special case when membership is a set.
-- Viewing two tags at once is possible when selection is a set. A single-
-- current-workspace model cannot be widened into either afterwards without
-- breaking every caller. Both are sets from the start. The design is
-- awesome's shape and none of its code. CREDITS.md records that awesome is
-- GPL-2 and lunette GPL-3-only.
--
-- Membership is held strongly. Dead panels are removed at the next lookup. A
-- panel is destroyed explicitly, not collected. No signal connection is
-- needed to remove it; `panels` compacts. A tag holding a destroyed panel
-- between one call and the next costs a table entry.
--
-- `mullion.tag.current` is one of the two module paths docs/lua-api.md
-- attests. The name is fixed. It answers the selected tags, not one tag,
-- because selection is multi.

local signal = require '@mullion/signal'
local teardown = require '@mullion/teardown'

local tag = {}

-- `methods` is filled in after the public API, which keeps the public API
-- first. The metatable is a table, not a forward-declared local, because
-- `new` reads it while the methods below are still unfilled.
local methods = {}
local metatable = { __index = methods }
local compact, indexOf, byIndex

type TagOptions = {
  index: number?,
  selected: boolean?,
  layout: ((members: { Panel }) -> ())?,
}

-- Anything with a pose: a `mullion.panel` panel is one, and so is an object of
-- a configuration's own. `setPose` names no receiver, because a type that named
-- this one would refuse the panel whose own methods take itself.
export type Panel = {
  read dead: boolean,
  read setPose: (any, Mat4) -> (),
}

export type Tag = {
  name: string,
  index: number,
  selected: boolean,
  layout: ((members: { Panel }) -> ())?,
  dead: boolean,
  members: { Panel },
  add: (Tag, Panel) -> boolean,
  remove: (Tag, Panel) -> boolean,
  has: (Tag, Panel) -> boolean,
  panels: (Tag) -> { Panel },
  setSelected: (Tag, boolean) -> boolean,
  apply: (Tag) -> boolean,
  destroy: (Tag) -> boolean,
}

local _tagPrototype: Tag = setmetatable({
  name = '',
  index = 1,
  selected = false,
  layout = nil,
  dead = false,
  members = {},
}, metatable) :: Tag

-- Every tag, in creation order. Rebuilt at module load, so a soft reload
-- starts with none.
local tags: { Tag } = {}

-- A fresh tag.
--
-- `options` takes `index`, defaulting to one past the last tag's; `selected`,
-- off by default; and `layout`, a function taking the tag's panels.
--
-- A name another tag already holds raises. A configuration and a saved
-- arrangement refer to a tag by its name, and two tags sharing one name would
-- make `find` arbitrary.
function tag.new(name: string, options: TagOptions?): Tag
  if type(name) ~= 'string' then
    error('mullion.tag: a tag is named by a string, not a ' .. type(name), 2)
  end
  if tag.find(name) then
    error("mullion.tag: a tag named '" .. name .. "' already exists", 2)
  end
  options = options or ({} :: TagOptions)
  if options.layout ~= nil and type(options.layout) ~= 'function' then
    error("mullion.tag: the layout of '" .. name .. "' is a function, not a " .. type(options.layout), 2)
  end

  local created: Tag = setmetatable({
    name = name,
    index = options.index or (#tags + 1),
    selected = options.selected and true or false,
    layout = options.layout,
    dead = false,
    -- Ordered, because a layout arranges panels in an order and a set has none.
    members = {} :: { Panel },
  }, metatable) :: Tag

  tags[#tags + 1] = created
  return created
end

-- Every live tag, ordered by index and then by name.
--
-- Two configurations declaring the same tags in a different order arrange
-- them the same way because the order is index and name, not creation order.
-- A saved arrangement names a tag, and the name resolves to the same tag in
-- every configuration.
function tag.all(): { Tag }
  local live: { Tag } = {}
  for _, existing in ipairs(tags) do
    if not existing.dead then
      live[#live + 1] = existing
    end
  end
  table.sort(live, byIndex)
  return live
end

-- The live tag named `name`, or nothing.
function tag.find(name: string): Tag?
  for _, existing in ipairs(tags) do
    if not existing.dead and existing.name == name then
      return existing
    end
  end
  return nil
end

-- The selected tags, in `all` order.
--
-- Empty when nothing is selected. A missing selection is not an error: a
-- layout handed no tags arranges nothing.
function tag.current(): { Tag }
  local selected: { Tag } = {}
  for _, existing in ipairs(tag.all()) do
    if existing.selected then
      selected[#selected + 1] = existing
    end
  end
  return selected
end

-- Selects `chosen` and deselects every other tag.
--
-- The single-select case. A configuration switching workspaces with a key
-- uses it. Multi-select is `tagObject:setSelected(true)` on each.
function tag.only(chosen: Tag)
  for _, existing in ipairs(tag.all()) do
    existing:setSelected(existing == chosen)
  end
end

-- Whether `value` is a tag.
--
-- Public because `panelsOf` dispatches on it, and a configuration writing its
-- own layout needs the same dispatch.
function tag.isTag(value: unknown): boolean
  return type(value) == 'table' and getmetatable(value) == metatable
end

-- The live panels of `target`, deduplicated, as a fresh array.
--
-- `target` is a tag, an array of tags, or an array of panels. A layout is
-- handed `tag.current()` or a list a configuration assembled itself. The
-- dispatch is total: an array holding both tags and panels raises.
--
-- Deduplication makes membership a set, not a list. A panel on two selected
-- tags appears once, and a layout does not place it twice. Placing it twice
-- leaves it at the position of the second placement.
function tag.panelsOf(target: Tag | { Tag } | { Panel }): { Panel }
  if target == nil then
    error('mullion.tag: panels are of a tag or an array, and nil is neither', 2)
  end
  local targetTag = tag.isTag(target) and (target :: Tag) or nil
  if targetTag then
    return targetTag:panels()
  end
  if type(target) ~= 'table' then
    error('mullion.tag: panels are of a tag or an array, not a ' .. type(target), 2)
  end

  local panels: { Panel } = {}
  local seen: { [Panel]: boolean } = {}
  local holdsTags = nil
  for index = 1, #target do
    local item = target[index]
    local itemTag = tag.isTag(item) and (item :: Tag) or nil
    local isTag = itemTag ~= nil
    if holdsTags == nil then
      holdsTags = isTag
    elseif holdsTags ~= isTag then
      error('mullion.tag: an array holds tags or panels, not both', 2)
    end

    if itemTag then
      for _, member in ipairs(itemTag:panels()) do
        if not seen[member] then
          seen[member] = true
          panels[#panels + 1] = member
        end
      end
    elseif type(item) == 'table' and not item.dead and not seen[item] then
      seen[item] = true
      panels[#panels + 1] = item
    end
  end
  return panels
end

-- Destroys every tag. Registered as this module's teardown hook. A soft
-- reload that keeps the old state's tags makes the new state's `tag.new`
-- raise on names the configuration declares for the first time.
function tag.teardown()
  for _, existing in ipairs(tags) do
    existing.dead = true
    existing.members = {} :: { Panel }
    signal.disconnectAll(existing)
  end
  tags = {}
end

-- Adds `panel` to this tag, reporting whether the panel is a new member.
-- Membership is a set, and adding twice adds once.
function methods:add(panel)
  if self.dead or panel == nil or panel.dead then
    return false
  end
  if indexOf(self.members, panel) then
    return false
  end

  self.members[#self.members + 1] = panel
  signal.emit(self, 'tagged', panel)
  return true
end

-- Takes `panel` off this tag, reporting whether the removal took place.
function methods:remove(panel)
  local at = indexOf(self.members, panel)
  if not at then
    return false
  end

  table.remove(self.members, at)
  signal.emit(self, 'untagged', panel)
  return true
end

-- Whether `panel` is a live member of this tag.
function methods:has(panel)
  compact(self.members)
  return indexOf(self.members, panel) ~= nil
end

-- This tag's live panels, in the order of addition, as a fresh array.
function methods:panels()
  compact(self.members)
  local members = {}
  for index = 1, #self.members do
    members[index] = self.members[index]
  end
  return members
end

-- Selects or deselects the tag, announcing `property::selected`.
--
-- Selection changes go through `signal.setProperty`. A configuration hears
-- about a selection change and does not poll for one. Setting the tag to what
-- it already is announces nothing.
function methods:setSelected(selected)
  if self.dead then
    return false
  end
  return signal.setProperty(self, 'selected', selected and true or false)
end

-- Runs this tag's layout over its panels, reporting whether there is one.
--
-- A tag that is not selected does not arrange itself. A layout places panels
-- where the user can see them. A tag the user is not looking at has no such
-- place. Arranging it would move panels the user cannot see into the space
-- occupied by panels the user can see.
function methods:apply()
  if self.dead or not self.selected then
    return false
  end
  local layout = self.layout
  if not layout then
    return false
  end
  layout(self:panels())
  return true
end

-- Withdraws the tag. Its panels are untouched. A tag holds panels and does
-- not own them, and a panel on two tags remains when either tag is destroyed.
function methods:destroy()
  if self.dead then
    return false
  end

  self.dead = true
  self.members = {} :: { Panel }
  for index = 1, #tags do
    if tags[index] == self then
      table.remove(tags, index)
      break
    end
  end
  signal.emit(self, 'destroyed')
  signal.disconnectAll(self)
  return true
end

-- Drops destroyed panels from `members`, in place and in order. This keeps a
-- long session from accumulating them.
function compact(members)
  local kept = 0
  for index = 1, #members do
    local member = members[index]
    if not member.dead then
      kept = kept + 1
      members[kept] = member
    end
  end
  for index = #members, kept + 1, -1 do
    members[index] = nil
  end
end

-- The position of `panel` in `members`, or nothing.
function indexOf(members: { Panel }, panel: Panel): number?
  for index = 1, #members do
    if members[index] == panel then
      return index
    end
  end
  return nil
end

-- Orders tags by index and then by name. The name tiebreak keeps two tags
-- sharing an index in a fixed order; `table.sort` alone would order them
-- arbitrarily.
function byIndex(left: Tag, right: Tag)
  if left.index ~= right.index then
    return left.index < right.index
  end
  return left.name < right.name
end

-- Registered by name. A module body running a second time, as during a soft
-- reload, leaves one hook and not two.
teardown.register('mullion.tag', tag.teardown)

return tag

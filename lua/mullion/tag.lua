-- Tags: named groups of panels, and which of them the user is looking at.
--
-- docs/stdlib.md's tier 3, the part that decides what is shown. A tag has a
-- name, an index, a selected flag, and a layout attached, and a panel belongs to
-- a set of tags rather than to one workspace.
--
-- The set is the load-bearing part. "Show this panel on two tags" is expressible
-- without a special case only when membership is a set, and viewing two tags at
-- once is possible only when selection is. A single-current-workspace model
-- cannot be widened into either afterwards without breaking every caller, so it
-- is a set from the start. This is awesome's shape and none of its code:
-- docs/decisions.md records that awesome is GPL-2 and lunette GPL-3-only.
--
-- Membership is held strongly and dead panels are dropped when they are next
-- looked for. A panel is destroyed explicitly rather than collected, so there is
-- nothing here to connect to a signal for; `panels` compacts, and a tag holding
-- a destroyed panel between one call and the next costs a table entry.
--
-- `mullion.tag.current` is one of the two module paths docs/lua-api.md attests,
-- so that name is fixed. It answers the selected tags rather than one tag,
-- because selection is multi.

local signal = require 'mullion.signal'
local teardown = require 'mullion.teardown'

local tag = {}

-- Declared here and defined below the public API, so the file reads
-- surface-first. The metatable is a table rather than a forward-declared local
-- because `new` reads it before the methods below are filled in.
local methods = {}
local metatable = { __index = methods }
local compact, indexOf, byIndex

-- Every tag, in creation order. Rebuilt when this file runs, so a soft reload
-- starts with none.
local tags = {}

-- A fresh tag.
--
-- `options` takes `index`, defaulting to one past the last tag's; `selected`,
-- off by default; and `layout`, a function taking the tag's panels.
--
-- A name another tag already holds raises. The name is what a configuration and
-- a saved arrangement both refer to a tag by, and two tags answering to one name
-- would make `find` a coin toss.
function tag.new(name, options)
  if type(name) ~= 'string' then
    error('mullion.tag: a tag is named by a string, not a ' .. type(name), 2)
  end
  if tag.find(name) then
    error("mullion.tag: a tag named '" .. name .. "' already exists", 2)
  end
  options = options or {}
  if options.layout ~= nil and type(options.layout) ~= 'function' then
    error("mullion.tag: the layout of '" .. name .. "' is a function, not a " .. type(options.layout), 2)
  end

  local created = setmetatable({
    name = name,
    index = options.index or (#tags + 1),
    selected = options.selected and true or false,
    layout = options.layout,
    dead = false,
    -- Ordered, because a layout arranges panels in an order and a set has none.
    members = {},
  }, metatable)

  tags[#tags + 1] = created
  return created
end

-- Every live tag, ordered by index and then by name.
--
-- Ordered rather than in creation order so that two configurations declaring the
-- same tags in a different order arrange them the same way, and so that a saved
-- arrangement naming a tag lands on the same one it was written from.
function tag.all()
  local live = {}
  for _, existing in ipairs(tags) do
    if not existing.dead then
      live[#live + 1] = existing
    end
  end
  table.sort(live, byIndex)
  return live
end

-- The live tag named `name`, or nothing.
function tag.find(name)
  for _, existing in ipairs(tags) do
    if not existing.dead and existing.name == name then
      return existing
    end
  end
  return nil
end

-- The selected tags, in `all` order.
--
-- Empty when nothing is selected, which is a configuration that has not chosen
-- yet rather than an error: a layout handed no tags arranges nothing.
function tag.current()
  local selected = {}
  for _, existing in ipairs(tag.all()) do
    if existing.selected then
      selected[#selected + 1] = existing
    end
  end
  return selected
end

-- Selects `chosen` and deselects every other tag.
--
-- The single-select case, which is what a configuration switching workspaces
-- with a key wants. Multi-select is `tagObject:setSelected(true)` on each.
function tag.only(chosen)
  for _, existing in ipairs(tag.all()) do
    existing:setSelected(existing == chosen)
  end
end

-- Whether `value` is a tag.
--
-- Public because `panelsOf` dispatches on it and a configuration writing its own
-- layout wants the same dispatch.
function tag.isTag(value)
  return type(value) == 'table' and getmetatable(value) == metatable
end

-- The live panels of `target`, deduplicated, as a fresh array.
--
-- `target` is a tag, an array of tags, or an array of panels, so that a layout
-- can be handed `tag.current()` or a list a configuration assembled itself. The
-- dispatch is total: an array holding both raises rather than guessing.
--
-- Deduplication is what makes membership a set rather than a list. A panel on
-- two selected tags appears once, so a layout does not place it twice and then
-- leave it wherever the second placement put it.
function tag.panelsOf(target)
  if target == nil then
    error('mullion.tag: panels are of a tag or an array, and nil is neither', 2)
  end
  if tag.isTag(target) then
    return target:panels()
  end
  if type(target) ~= 'table' then
    error('mullion.tag: panels are of a tag or an array, not a ' .. type(target), 2)
  end

  local panels, seen = {}, {}
  local holdsTags = nil
  for index = 1, #target do
    local item = target[index]
    local isTag = tag.isTag(item)
    if holdsTags == nil then
      holdsTags = isTag
    elseif holdsTags ~= isTag then
      error('mullion.tag: an array holds tags or panels, not both', 2)
    end

    if isTag then
      for _, member in ipairs(item:panels()) do
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

-- Destroys every tag. Registered as this module's teardown hook, because a soft
-- reload that left the old state's tags behind would leave the new state's
-- `tag.new` raising on names the user believes they are declaring for the first
-- time.
function tag.teardown()
  for _, existing in ipairs(tags) do
    existing.dead = true
    existing.members = {}
    signal.disconnectAll(existing)
  end
  tags = {}
end

-- Adds `panel` to this tag, reporting whether it was not already on it.
--
-- Membership is a set, so adding twice adds once.
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

-- Takes `panel` off this tag, reporting whether it was on it.
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

-- This tag's live panels, in the order they were added, as a fresh array.
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
-- Through `signal.setProperty`, so that a configuration hears about a selection
-- change rather than polling for one, and so that setting it to what it already
-- is says nothing.
function methods:setSelected(selected)
  if self.dead then
    return false
  end
  return signal.setProperty(self, 'selected', selected and true or false)
end

-- Runs this tag's layout over its panels, reporting whether there was one.
--
-- A tag that is not selected does not arrange itself. A layout places panels
-- where the user can see them, and a tag the user is not looking at has no such
-- place; arranging it anyway would move panels the user cannot see into the
-- space occupied by the ones they can.
function methods:apply()
  if self.dead or not self.selected or not self.layout then
    return false
  end
  self.layout(self:panels())
  return true
end

-- Withdraws the tag. Its panels are untouched: a tag holds panels and does not
-- own them, and a panel on two tags outlives either.
function methods:destroy()
  if self.dead then
    return false
  end

  self.dead = true
  self.members = {}
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

-- Drops destroyed panels from `members`, in place and in order, so that a long
-- session does not accumulate them.
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

-- Where `panel` sits in `members`, or nothing.
function indexOf(members, panel)
  for index = 1, #members do
    if members[index] == panel then
      return index
    end
  end
  return nil
end

-- Orders tags by index and then by name, so that two tags sharing an index still
-- have one order rather than whichever `table.sort` happened to produce.
function byIndex(left, right)
  if left.index ~= right.index then
    return left.index < right.index
  end
  return left.name < right.name
end

-- Registered by name, so that a module body running a second time — which is
-- what a soft reload does — leaves one hook rather than two.
teardown.register('mullion.tag', tag.teardown)

return tag

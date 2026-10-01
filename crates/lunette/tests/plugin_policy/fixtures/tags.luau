-- Tags: held tags, exclusions, layout overrides, and change events.
local plugin = require '@lunette-plugin'
local tags = require '@lunette-contracts/tags'
local native = require '@lunette'

local reported = {}
native.reportError = function(fields)
  reported[#reported + 1] = fields
end

local runtime = plugin.runtime()
runtime:use(require('@lunette-plugins/tags').definition, {}):enable()

local function consumer(name)
  local handle = {}
  handle.instance = runtime:use(
    plugin.define {
      name = name,
      requires = { tags = tags.capability },
      init = function(context)
        handle.owner = context
        handle.tags = context:require(tags.capability)
      end,
    },
    {}
  )
  handle.instance:enable()
  return handle
end

local first, second, third = consumer 'tags-1', consumer 'tags-2', consumer 'tags-3'
local service = first.tags
local changes = {}
service:onChanged(third.owner, {
  run = function(change)
    changes[#changes + 1] = change.kind .. ':' .. change.tag.name
  end,
})

-- A held tag is made by whichever holder comes first and lasts while any
-- holder remains; the options of the call that makes it apply.
local held, firstHold = service:hold(first.owner, { name = 'shared', selected = true, layout = 'grid' })
assert(held.selected and held.layout == 'grid', 'the options of the call that makes the tag apply')
assert(changes[1] == 'created:shared', 'making a tag is announced: ' .. tostring(changes[1]))
local again, secondHold = service:hold(second.owner, { name = 'shared', selected = false })
assert(again == held and held.selected, 'a later hold answers the tag and does not change it')
local same, sameHold = service:hold(second.owner, { name = 'shared' })
assert(same == held and sameHold == secondHold, 'an owner holds a tag once')
first.instance:disable()
assert(not held.dead and service:find 'shared' == held, 'the tag outlives a holder that unloads')
secondHold:dispose()
assert(held.dead and service:find 'shared' == nil, 'the tag ends with its last holder')
assert(changes[#changes] == 'destroyed:shared', 'the end is announced')
first.instance:enable()
service = first.tags
firstHold:dispose()

-- new raises on a held name, and holding a tag new made borrows it.
service:hold(first.owner, { name = 'held-first' })
assert(not pcall(function()
  service:new(second.owner, 'held-first')
end), 'new raises on a name that is held')
local owned = service:new(second.owner, 'owned')
local borrowed, borrowHold = service:hold(first.owner, { name = 'owned' })
assert(borrowed == owned)
borrowHold:dispose()
assert(not owned.dead, 'releasing a borrow leaves the tag')
for _, malformed in ipairs {
  { name = '' },
  { name = 'x', colour = 'red' },
  { name = 'x', selected = 'yes' },
  { name = 'x', layout = 3 },
} do
  assert(not pcall(function()
    service:hold(first.owner, malformed)
  end), 'a malformed hold raises')
end

-- A membership is held by its owners and an exclusion by its excluders; a
-- panel is a member while a membership remains and no exclusion does.
local panel = { dead = false }
table.clear(changes)
assert(owned:add(second.owner, panel) and owned:has(panel))
assert(changes[1] == 'membership:owned', 'adding a member is announced')
assert(not pcall(function()
  owned:remove(first.owner, panel)
end), 'an owner cannot remove a membership it does not hold')
local exclusion = owned:exclude(first.owner, { panel = panel })
assert(not owned:has(panel) and #owned.members == 0, 'an excluded panel is not a member')
assert(changes[2] == 'membership:owned', 'excluding a member is announced')
assert(owned:exclude(first.owner, { panel = panel }) == exclusion, 'an owner holds one exclusion of a panel')
local otherTag = service:new(first.owner, 'elsewhere')
otherTag:add(first.owner, panel)
assert(otherTag:has(panel), 'an exclusion moves a window between tags with an add')
exclusion:dispose()
assert(owned:has(panel), 'the panel returns when the exclusion ends')
owned:exclude(third.owner, { panel = panel })
assert(not owned:has(panel))
third.instance:disable()
assert(owned:has(panel), 'an exclusion ends with its owner')
third.instance:enable()
for _, malformed in ipairs { 'panel', { panel = panel, also = true }, { panel = 3 } } do
  assert(not pcall(function()
    owned:exclude(first.owner, malformed)
  end), 'a malformed exclusion raises')
end

-- A layout is an override like a selection: the most recent live one
-- decides, a nil layout is an override of its own, and an owner's ends with
-- it.
local listened = {}
service:onChanged(third.owner, {
  tag = owned,
  run = function(change)
    listened[#listened + 1] = change.kind
  end,
})
assert(owned.layout == nil)
assert(owned:setLayout(first.owner, { layout = 'arc' }) and owned.layout == 'arc')
assert(owned:setLayout(second.owner, { layout = 'grid' }) and owned.layout == 'grid')
assert(not owned:setLayout(second.owner, { layout = 'grid' }), 'an unchanged layout answers false')
assert(owned:setLayout(first.owner, {}) and owned.layout == nil, 'a nil layout is an override')
first.instance:disable()
assert(owned.layout == 'grid', "an unloading owner's layout override ends")
first.instance:enable()
assert(listened[1] == 'layout' and #listened >= 3, 'a listener for one tag hears its layout changes')
local elsewhereHeard = #listened
service = first.tags
service:new(first.owner, 'quiet'):setSelected(first.owner, { selected = true })
assert(#listened == elsewhereHeard, 'a listener for one tag does not hear another')
for _, malformed in ipairs { 'grid', { layout = 3 }, { layout = 'grid', also = true } } do
  assert(not pcall(function()
    owned:setLayout(second.owner, malformed)
  end), 'a malformed layout choice raises')
end

-- A listener that raises is reported, and the others still run.
local heard = false
service:onChanged(first.owner, {
  run = function()
    error 'fixture: change listener failure'
  end,
})
service:onChanged(second.owner, {
  run = function()
    heard = true
  end,
})
service:new(second.owner, 'noisy')
assert(heard, 'a raising listener does not stop the next')
assert(#reported >= 1 and tostring(reported[#reported].message):find('change listener failure', 1, true))
for _, malformed in ipairs {
  'listener',
  { run = 'listener' },
  { run = function() end, when = true },
  { run = function() end, tag = { name = 'not a tag' } },
} do
  assert(not pcall(function()
    service:onChanged(first.owner, malformed)
  end), 'a malformed listener raises')
end

-- Only the owner that made a tag destroys it, and a held tag ends only when
-- its last holder lets go.
local mine = service:new(second.owner, 'mine')
local ok, failure = pcall(function()
  return mine:destroy(first.owner)
end)
assert(not ok and tostring(failure):find("only the owner that made the tag 'mine' destroys it", 1, true), failure)
assert(not mine.dead, 'a refused destroy leaves the tag')
assert(mine:destroy(second.owner) and mine.dead, 'its owner destroys it')
assert(not mine:destroy(second.owner), 'a dead tag answers false')
local held, holding = service:hold(first.owner, { name = 'shared' })
ok, failure = pcall(function()
  return held:destroy(first.owner)
end)
assert(not ok and tostring(failure):find("the tag 'shared' is held", 1, true), failure)
assert(not held.dead)
holding:dispose()
assert(held.dead, 'a held tag ends when its last holder lets go')

runtime:close()

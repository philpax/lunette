-- Covers lua/mullion/tag.lua.
--
-- The selected tags determine the panels a layout receives. The cases concern
-- the membership set: a panel on two tags appears once, an unselected tag is
-- not returned by `current`, and a destroyed panel leaves the set at the next
-- lookup without a notification.

local expect = require '@spec/expect'
local suite = require '@spec/suite'

local tag = require '@mullion/tag'

local spec = suite.new 'mullion.tag'

-- For a tag, a panel is an object with a `dead` flag and a pose. Nothing a tag
-- does reaches past those two fields. The cases never require `mullion.panel`;
-- requiring it would make them depend on the layer-claim fake the panel specs
-- install.
local function newPanel(name)
  return { name = name, dead = false }
end

-- A fresh registry for each case. `tag.new` raises on a name another tag
-- holds. Leftover tags would make the next case raise.
local function reset()
  tag.teardown()
end

spec('a tag carries a name, an index, and a selected flag', function()
  reset()
  local main = tag.new('main', { index = 3, selected = true })

  expect.equal(main.name, 'main', 'the name')
  expect.equal(main.index, 3, 'the index')
  expect.equal(main.selected, true, 'the selected flag')
end)

spec('a tag with no index takes one past the last', function()
  reset()
  tag.new 'first'
  local second = tag.new 'second'

  expect.equal(second.index, 2, 'the second tag index')
end)

spec('a name another tag holds raises', function()
  reset()
  tag.new 'main'

  expect.raises(function()
    tag.new 'main'
  end, 'already exists', 'a duplicate name')
end)

spec('tags are ordered by index and then by name', function()
  reset()
  tag.new('c', { index = 2 })
  tag.new('a', { index = 1 })
  tag.new('b', { index = 1 })

  local names = {}
  for _, existing in ipairs(tag.all()) do
    names[#names + 1] = existing.name
  end
  expect.equal(table.concat(names, ','), 'a,b,c', 'the order')
end)

spec('a panel added twice is a member once', function()
  reset()
  local main = tag.new 'main'
  local panel = newPanel 'one'

  expect.equal(main:add(panel), true, 'the first add')
  expect.equal(main:add(panel), false, 'the second add')
  expect.equal(#main:panels(), 1, 'the members')
end)

spec('removing a panel takes it off the tag', function()
  reset()
  local main = tag.new 'main'
  local panel = newPanel 'one'
  main:add(panel)

  expect.equal(main:remove(panel), true, 'the removal')
  expect.equal(main:has(panel), false, 'membership afterwards')
  expect.equal(main:remove(panel), false, 'removing it again')
end)

spec('a destroyed panel stops being a member', function()
  reset()
  local main = tag.new 'main'
  local kept, going = newPanel 'kept', newPanel 'going'
  main:add(kept)
  main:add(going)

  going.dead = true

  local members = main:panels()
  expect.equal(#members, 1, 'the members')
  expect.equal(members[1], kept, 'the surviving member')
end)

spec('only the selected tags are current', function()
  reset()
  local main = tag.new('main', { selected = true })
  tag.new 'other'

  local current = tag.current()
  expect.equal(#current, 1, 'the current tags')
  expect.equal(current[1], main, 'the current tag')
end)

spec('two tags can be selected at once', function()
  reset()
  local main = tag.new('main', { selected = true })
  local side = tag.new('side', { selected = true })

  local current = tag.current()
  expect.equal(#current, 2, 'the current tags')
  expect.equal(current[1], main, 'the first')
  expect.equal(current[2], side, 'the second')
end)

spec('only selects one tag and deselects the rest', function()
  reset()
  local main = tag.new('main', { selected = true })
  local side = tag.new 'side'

  tag.only(side)

  expect.equal(main.selected, false, 'the tag that was selected')
  expect.equal(side.selected, true, 'the tag that was chosen')
end)

spec('selecting announces the property change once', function()
  reset()
  local signal = require '@mullion/signal'
  local main = tag.new 'main'
  local announced = 0
  local handler = function()
    announced = announced + 1
  end
  signal.connect(main, signal.propertyName 'selected', handler)

  main:setSelected(true)
  main:setSelected(true)

  expect.equal(announced, 1, 'the announcements')
end)

spec('a panel on two selected tags appears once', function()
  reset()
  local main = tag.new('main', { selected = true })
  local side = tag.new('side', { selected = true })
  local shared, only = newPanel 'shared', newPanel 'only'
  main:add(shared)
  side:add(shared)
  side:add(only)

  local panels = tag.panelsOf(tag.current())
  expect.equal(#panels, 2, 'the panels')
  expect.equal(panels[1], shared, 'the shared panel')
  expect.equal(panels[2], only, 'the other panel')
end)

spec('panelsOf takes a tag, an array of tags, or an array of panels', function()
  reset()
  local main = tag.new 'main'
  local panel = newPanel 'one'
  main:add(panel)

  expect.equal(#tag.panelsOf(main), 1, 'a tag')
  expect.equal(#tag.panelsOf { main }, 1, 'an array of tags')
  expect.equal(#tag.panelsOf { panel }, 1, 'an array of panels')
  expect.equal(#tag.panelsOf {}, 0, 'an empty array')
end)

spec('panelsOf refuses an array holding both', function()
  reset()
  local main = tag.new 'main'

  expect.raises(function()
    tag.panelsOf { main, newPanel 'one' }
  end, 'not both', 'a mixed array')

  expect.raises(function()
    tag.panelsOf(nil)
  end, 'nil is neither', 'nothing at all')
end)

spec('an unselected tag does not apply its layout', function()
  reset()
  local applied = 0
  local main = tag.new('main', {
    layout = function()
      applied = applied + 1
    end,
  })
  main:add(newPanel 'one')

  expect.equal(main:apply(), false, 'applying an unselected tag')
  expect.equal(applied, 0, 'the layout calls')

  main:setSelected(true)
  expect.equal(main:apply(), true, 'applying a selected tag')
  expect.equal(applied, 1, 'the layout calls afterwards')
end)

spec('a layout that is not a function raises at declaration', function()
  reset()

  expect.raises(function()
    tag.new('main', { layout = 'arc' })
  end, 'is a function', 'a layout that is a string')
end)

spec('destroying a tag leaves its panels alone', function()
  reset()
  local main = tag.new 'main'
  local side = tag.new 'side'
  local panel = newPanel 'one'
  main:add(panel)
  side:add(panel)

  expect.equal(main:destroy(), true, 'the destruction')
  expect.equal(#tag.all(), 1, 'the remaining tags')
  expect.equal(side:has(panel), true, 'membership of the other tag')
  expect.equal(panel.dead, false, 'the panel')
end)

spec('teardown empties the registry', function()
  reset()
  tag.new 'main'

  tag.teardown()

  expect.equal(#tag.all(), 0, 'the tags afterwards')
  -- The name is free again. A soft reload re-runs the configuration, which
  -- declares its tags by name; leftover tags would make the declaration raise.
  expect.truthy(tag.new 'main', 'declaring the same name again')
end)

spec('requiring twice leaves one teardown hook', function()
  reset()
  local teardown = require '@mullion/teardown'
  package.loaded['@mullion/tag'] = nil
  local reloaded = require '@mullion/tag'
  package.loaded['@mullion/tag'] = tag

  local registered = 0
  for _, name in ipairs(teardown.pending()) do
    if name == 'mullion.tag' then
      registered = registered + 1
    end
  end
  expect.equal(registered, 1, 'the hooks named mullion.tag')
  -- The second module body builds its own registry. The first body's tags are
  -- not in the second body's registry. Emptying both registries leaves the rest
  -- of the suite with the registry it expects.
  reloaded.teardown()
  tag.teardown()
  -- The second body's `register` replaces the hook with its own registry's
  -- teardown. Registering the first module table's teardown restores the first
  -- hook: the rest of the suite holds the first module table, and a reload
  -- would otherwise empty a registry nothing is using.
  teardown.register('mullion.tag', tag.teardown)
end)

return spec

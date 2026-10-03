-- Covers the tags provider: owned and held tags, the owner-scoped memberships, exclusions, selections, and
-- layouts on them, the queries over them, and their change events.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local tagsContract = require '@lunette-contracts/tags'

local test = testing.suite()

-- The tags provider over the fake native API, and `consumer(name)` adding a plugin of its own that requires
-- tags, answered as `{ instance, owner, tags }`. Its owner and service are replaced each time it is enabled
-- again.
local function start()
  local fake = testing.native()
  local session = testing.start { 'tags' }
  local function consumer(name)
    local handle = {}
    handle.instance = session:use(plugin.define {
      name = name,
      requires = { tags = tagsContract.capability },
      init = function(context)
        handle.owner = context
        handle.tags = context:require(tagsContract.capability)
      end,
    })
    return handle
  end
  return session, consumer, fake
end

local function panel()
  return { dead = false }
end

test('only the owner that made a tag destroys it, and a destroyed tag is not retained', function()
  local session, consumer = start()
  local maker, other = consumer 'maker', consumer 'other'
  local tags = maker.tags
  local mine = tags:new(maker.owner, 'mine')
  expect.equal(tags:find 'mine', mine, 'a new tag is found by name')
  expect.raises(function()
    mine:destroy(other.owner)
  end, "only the owner that made the tag 'mine' destroys it", 'another owner destroying it')
  expect.falsy(mine.dead, 'a refused destroy leaves the tag')
  expect.truthy(mine:destroy(maker.owner), 'its owner destroys it')
  expect.truthy(mine.dead, 'the destroyed tag')
  expect.equal(tags:find 'mine', nil, 'a destroyed tag is not found')
  expect.falsy(mine:destroy(maker.owner), 'a dead tag answers false')

  local weak = setmetatable({}, { __mode = 'v' })
  do
    local temporary = tags:new(maker.owner, 'temporary')
    weak[1] = temporary
    temporary:destroy(maker.owner)
  end
  testing.collect()
  expect.equal(weak[1], nil, 'a destroyed tag retained by its live owner')
  session:close()
end)

test('a stranger without the tags capability cannot make a tag', function()
  local session = start()
  local tags = session:observe(tagsContract.capability).service
  session:use(plugin.define {
    name = 'stranger',
    init = function(context)
      expect.raises(function()
        tags:new(context, 'forbidden')
      end, nil, 'a tag made for a context that does not require tags')
    end,
  })
  session:close()
end)

test('current answers the selected tags, and only selects one tag for its owner', function()
  local session, consumer = start()
  local first, second = consumer 'first', consumer 'second'
  local tags = first.tags
  local one = tags:new(first.owner, 'one', { selected = true })
  local two = tags:new(first.owner, 'two')
  local three = tags:new(first.owner, 'three', { selected = true })
  local current = tags:current()
  expect.equal(#current, 2, 'the selected tags')
  expect.equal(current[1], one, 'the first selected tag')
  expect.equal(current[2], three, 'the second selected tag')
  tags:only(second.owner, two)
  current = tags:current()
  expect.equal(#current, 1, 'the selected tags after only')
  expect.equal(current[1], two, 'the chosen tag')
  second.instance:disable()
  expect.equal(#tags:current(), 2, "an unloading owner's selections end with it")
  expect.truthy(one.selected and three.selected and not two.selected, 'the selections before it')
  session:close()
end)

test("an owner's selections and memberships are its own, and end with it", function()
  local session, consumer = start()
  local owner, borrower = consumer 'owner', consumer 'borrower'
  local tag = owner.tags:new(owner.owner, 'primary', { selected = true })
  expect.truthy(tag:setSelected(owner.owner, { selected = false }), 'a selection that changes answers true')
  expect.falsy(tag.selected, 'the selection')
  tag:setSelected(owner.owner, { selected = true })

  local borrowed = panel()
  expect.truthy(tag:setSelected(borrower.owner, { selected = false }), "the borrower's selection")
  expect.falsy(tag.selected, 'the most recent override decides')
  expect.truthy(tag:add(borrower.owner, borrowed), "the borrower's membership")
  expect.truthy(tag:has(borrowed), 'the member')
  borrower.instance:disable()
  expect.truthy(tag.selected, "an unloading owner's selection override is reverted")
  expect.falsy(tag:has(borrowed), "an unloading owner's membership is removed")

  borrower.instance:enable()
  local mine = panel()
  expect.truthy(tag:add(owner.owner, mine), "the owner's membership")
  expect.falsy(tag:add(owner.owner, mine), 'an owner holds a membership once')
  expect.truthy(tag:add(borrower.owner, borrowed), 'another membership')
  expect.raises(function()
    tag:remove(borrower.owner, mine)
  end, nil, 'removing a membership the caller does not hold')
  expect.truthy(tag:remove(owner.owner, borrowed), "the tag's owner removes another's membership")
  expect.falsy(tag:has(borrowed), "the tag's owner removes every hold")
  session:close()
end)

test('a held tag is made by its first holder and ends with its last', function()
  local session, consumer = start()
  local first, second, watcher = consumer 'first', consumer 'second', consumer 'watcher'
  local tags = first.tags
  local changes = {}
  tags:onChanged(watcher.owner, {
    run = function(change)
      changes[#changes + 1] = change.kind .. ':' .. change.tag.name
    end,
  })
  local held = tags:hold(first.owner, { name = 'shared', selected = true, layout = 'grid' })
  expect.truthy(held.selected, 'the options of the call that makes the tag apply')
  expect.equal(held.layout, 'grid', 'the layout it was made with')
  expect.equal(changes[1], 'created:shared', 'making a tag is announced')
  local again, secondHold = tags:hold(second.owner, { name = 'shared', selected = false })
  expect.equal(again, held, 'a later hold answers the same tag')
  expect.truthy(held.selected, 'a later hold does not change the tag')
  local _, sameHold = tags:hold(second.owner, { name = 'shared' })
  expect.equal(sameHold, secondHold, 'an owner holds a tag once')
  expect.raises(function()
    held:destroy(second.owner)
  end, "the tag 'shared' is held", 'destroying a held tag')
  expect.raises(function()
    tags:new(second.owner, 'shared')
  end, nil, 'new on a held name')
  first.instance:disable()
  expect.falsy(held.dead, 'the tag outlives a holder that unloads')
  secondHold:dispose()
  expect.truthy(held.dead, 'the tag ends with its last holder')
  expect.equal(tags:find 'shared', nil, 'an ended tag is not found')
  expect.equal(changes[#changes], 'destroyed:shared', 'the end is announced')

  local owned = tags:new(second.owner, 'owned')
  first.instance:enable()
  local borrowed, borrowHold = first.tags:hold(first.owner, { name = 'owned' })
  expect.equal(borrowed, owned, 'holding a tag new made borrows it')
  borrowHold:dispose()
  expect.falsy(owned.dead, 'releasing a borrow leaves the tag')
  session:close()
end)

test('an excluded panel is not a member until every exclusion of it ends', function()
  local session, consumer = start()
  local first, second, third = consumer 'first', consumer 'second', consumer 'third'
  local owned = first.tags:new(first.owner, 'owned')
  local elsewhere = first.tags:new(first.owner, 'elsewhere')
  local member = panel()
  owned:add(second.owner, member)
  local exclusion = owned:exclude(first.owner, { panel = member })
  expect.falsy(owned:has(member), 'an excluded panel is not a member')
  expect.equal(#owned.members, 0, 'the members while excluded')
  expect.equal(owned:exclude(first.owner, { panel = member }), exclusion, 'an owner holds one exclusion of a panel')
  elsewhere:add(first.owner, member)
  expect.truthy(elsewhere:has(member), 'an exclusion and an add move a panel between tags')
  owned:exclude(third.owner, { panel = member })
  exclusion:dispose()
  expect.falsy(owned:has(member), 'another exclusion still keeps it out')
  third.instance:disable()
  expect.truthy(owned:has(member), 'the panel returns when the last exclusion ends with its owner')
  session:close()
end)

test('the most recent live layout override decides, and a nil layout is an override', function()
  local session, consumer = start()
  local first, second, watcher = consumer 'first', consumer 'second', consumer 'watcher'
  local owned = watcher.tags:new(watcher.owner, 'owned')
  local heard = {}
  first.tags:onChanged(watcher.owner, {
    tag = owned,
    run = function(change)
      heard[#heard + 1] = change.kind
    end,
  })
  expect.equal(owned.layout, nil, 'a tag starts without a layout')
  expect.truthy(owned:setLayout(first.owner, { layout = 'arc' }), 'the first override')
  expect.truthy(owned:setLayout(second.owner, { layout = 'grid' }), 'a later override')
  expect.equal(owned.layout, 'grid', 'the most recent override decides')
  expect.falsy(owned:setLayout(second.owner, { layout = 'grid' }), 'an unchanged layout answers false')
  expect.truthy(owned:setLayout(first.owner, {}), 'a nil layout')
  expect.equal(owned.layout, nil, 'a nil layout is an override of its own')
  first.instance:disable()
  expect.equal(owned.layout, 'grid', "an unloading owner's layout override ends")
  expect.equal(table.concat(heard, ' '), 'layout layout layout layout', 'a listener for one tag hears its layouts')
  second.tags:new(second.owner, 'quiet'):setSelected(second.owner, { selected = true })
  expect.equal(#heard, 4, 'a listener for one tag does not hear another')
  session:close()
end)

test('a listener that raises is reported, and the listeners after it still run', function()
  local session, consumer, fake = start()
  local first = consumer 'first'
  local heard = false
  first.tags:onChanged(first.owner, {
    run = function()
      error 'change listener failure'
    end,
  })
  first.tags:onChanged(first.owner, {
    run = function()
      heard = true
    end,
  })
  first.tags:new(first.owner, 'noisy')
  expect.truthy(heard, 'a raising listener does not stop the next')
  expect.equal(#fake.events.reported, 1, 'the reports')
  expect.truthy(fake.events.reported[1].message:find('change listener failure', 1, true), 'the reported failure')
  session:close()
end)

test('panelsOf answers the panels of a tag, of several tags once each, or of a list of panels', function()
  local session, consumer = start()
  local first = consumer 'first'
  local tags = first.tags
  local one, two = tags:new(first.owner, 'one'), tags:new(first.owner, 'two')
  local a, b, gone = panel(), panel(), { dead = true }
  one:add(first.owner, a)
  two:add(first.owner, a)
  two:add(first.owner, b)
  expect.equal(#tags:panelsOf(one), 1, 'the panels of one tag')
  local union = tags:panelsOf { one, two }
  expect.equal(#union, 2, 'a panel in two tags is answered once')
  expect.equal(union[1], a, 'the panels in tag order')
  expect.equal(union[2], b, 'the second panel')
  local listed = tags:panelsOf { a, gone, a }
  expect.equal(#listed, 1, 'a list of panels without the dead or repeated')
  expect.raises(function()
    tags:panelsOf { one, a }
  end, 'tags or panels, not both', 'a list mixing tags and panels')
  expect.truthy(tags:isTag(one), 'a live tag is a tag')
  expect.falsy(tags:isTag { name = 'one', panels = function() end }, 'a table shaped like a tag is not one')
  one:destroy(first.owner)
  expect.falsy(tags:isTag(one), 'a destroyed tag is not a tag')
  session:close()
end)

return test

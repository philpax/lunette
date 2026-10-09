local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local tagsContract = require '@lunette-contracts/tags'

local test = testing.suite()

local function start()
  testing.native()
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
  return session, consumer
end

local function panel()
  return { dead = false }
end

test("an owner's selections and memberships are its own, and end with it", function()
  local session, consumer = start()
  local owner, borrower = consumer 'owner', consumer 'borrower'
  local tag = owner.tags:hold(owner.owner, { name = 'primary', selected = true })
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
  expect.truthy(tag:remove(borrower.owner, borrowed), 'an owner removes its own membership')
  expect.falsy(tag:has(borrowed), 'the removed membership')
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
  first.instance:disable()
  expect.falsy(held.dead, 'the tag outlives a holder that unloads')
  secondHold:dispose()
  expect.truthy(held.dead, 'the tag ends with its last holder')
  expect.equal(tags:find 'shared', nil, 'an ended tag is not found')
  expect.equal(changes[#changes], 'destroyed:shared', 'the end is announced')
  session:close()
end)

test('an excluded panel is not a member until every exclusion of it ends', function()
  local session, consumer = start()
  local first, second, third = consumer 'first', consumer 'second', consumer 'third'
  local owned = first.tags:hold(first.owner, { name = 'owned' })
  local elsewhere = first.tags:hold(first.owner, { name = 'elsewhere' })
  local member = panel()
  owned:add(second.owner, member)
  local exclusion = owned:exclude(first.owner, { panel = member })
  expect.falsy(owned:has(member), 'an excluded panel is not a member')
  expect.equal(#owned:panels(), 0, 'the members while excluded')
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
  local owned = watcher.tags:hold(watcher.owner, { name = 'owned' })
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
  second.tags:hold(second.owner, { name = 'quiet' }):setSelected(second.owner, { selected = true })
  expect.equal(#heard, 4, 'a listener for one tag does not hear another')
  session:close()
end)

return test

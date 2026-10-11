local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local tagsContract = require '@lunette-contracts/tags'

local test = testing.suite()

type Consumer = { instance: adapter.Instance<{}>?, owner: plugin.Context?, tags: tagsContract.Service? }
type Panel = { dead: boolean }

local function start(): (typeof(testing.start {}), (string) -> Consumer)
  testing.native()
  local session = testing.start { 'tags' }
  local function consumer(name: string): Consumer
    local handle: Consumer = {}
    handle.instance = session:use(adapter.define {
      name = name,
      requires = { tagsContract.capability },
      init = function(context: plugin.Context)
        handle.owner = context
        handle.tags = context:require(tagsContract.capability)
      end,
    })
    return handle
  end
  return session, consumer
end

local function panel(): Panel
  return { dead = false }
end

test("an owner's selections and memberships are its own, and end with it", function()
  local session, consumer = start()
  local owner, borrower = consumer 'owner', consumer 'borrower'
  local tag = owner.tags:hold(owner.owner, { name = 'primary' })
  tag:setSelected(owner.owner, true)
  local borrowed = panel()
  tag:setSelected(borrower.owner, false)
  expect.falsy(tag.selected, 'the most recent override decides')
  expect.truthy(tag:add(borrower.owner, borrowed), "the borrower's membership")
  expect.truthy(tag:has(borrowed), 'the member')
  borrower.instance:disable()
  expect.truthy(tag.selected, "an unloading owner's selection override is reverted")
  expect.falsy(tag:has(borrowed), "an unloading owner's membership is removed")
  session:close()
end)

test('a held tag is made by its first holder and ends with its last', function()
  local session, consumer = start()
  local first, second, watcher = consumer 'first', consumer 'second', consumer 'watcher'
  local tags = first.tags
  local changes: { string } = {}
  tags:onChanged(watcher.owner, {
    run = function(change: tagsContract.Change)
      changes[#changes + 1] = change.kind .. ':' .. change.tag.name
    end,
  })
  local held = tags:hold(first.owner, { name = 'shared', index = 5 })
  expect.equal(held.index, 5, 'the options of the call that makes the tag apply')
  expect.equal(changes[1], 'created:shared', 'making a tag is announced')
  local again, secondHold = tags:hold(second.owner, { name = 'shared', index = 9 })
  expect.equal(again, held, 'a later hold answers the same tag')
  expect.equal(held.index, 5, 'a later hold does not change the tag')
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
  local exclusion = owned:exclude(first.owner, member)
  expect.falsy(owned:has(member), 'an excluded panel is not a member')
  expect.equal(#owned:panels(), 0, 'the members while excluded')
  elsewhere:add(first.owner, member)
  expect.truthy(elsewhere:has(member), 'an exclusion and an add move a panel between tags')
  owned:exclude(third.owner, member)
  exclusion:dispose()
  expect.falsy(owned:has(member), 'another exclusion still keeps it out')
  third.instance:disable()
  expect.truthy(owned:has(member), 'the panel returns when the last exclusion ends with its owner')
  session:close()
end)

test('the most recent live selection override decides, and disposing it reveals the next', function()
  local session, consumer = start()
  local first, second, watcher = consumer 'first', consumer 'second', consumer 'watcher'
  local owned = watcher.tags:hold(watcher.owner, { name = 'owned' })
  local heard: { tagsContract.ChangeKind } = {}
  first.tags:onChanged(watcher.owner, {
    tag = owned,
    run = function(change: tagsContract.Change)
      heard[#heard + 1] = change.kind
    end,
  })
  expect.falsy(owned.selected, 'a tag starts unselected')
  local selecting = owned:setSelected(first.owner, true)
  local clearing = owned:setSelected(second.owner, false)
  expect.falsy(owned.selected, 'the most recent override decides')
  expect.equal(owned:setSelected(second.owner, false), clearing, 'an owner has one override')
  clearing:dispose()
  expect.truthy(owned.selected, 'disposing an override reveals the next')
  selecting:dispose()
  expect.falsy(owned.selected, 'no override leaves the tag unselected')
  expect.equal(
    table.concat(heard, ' '),
    'selection selection selection selection',
    'a listener for one tag hears its changes'
  )
  session:close()
end)

return test

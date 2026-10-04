local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local focusContract = require '@lunette-contracts/focus'

local test = testing.suite()

local function start()
  local env = { native = testing.native(), heard = {} }
  env.session = testing.start { 'focus' }
  local function consumer(name, key)
    return env.session:use(plugin.define {
      name = name,
      requires = { focus = focusContract.capability },
      init = function(context)
        env.focus = context:require(focusContract.capability)
        env[key] = context
      end,
    })
  end
  env.first = consumer('focus-first', 'owner')
  env.second = consumer('focus-second', 'other')
  local function newSeat()
    local seat = { dead = false }
    function seat:setFocus(sink)
      self.focus = sink
    end
    return seat
  end
  env.left, env.right = newSeat(), newSeat()
  env.sink, env.otherSink = { dead = false }, { dead = false }
  env.focus:onChanged(env.owner, {
    run = function(change)
      env.heard[#env.heard + 1] = change
    end,
  })
  return env
end

test('an owner holds one grant per seat, and moving it answers the same effect', function()
  local env = start()
  local grant = env.focus:setFocus(env.owner, { seat = env.left, sink = env.sink })
  expect.equal(env.left.focus, env.sink, 'the native focus')
  expect.equal(env.focus:focused(), env.left, 'the focused seat')
  expect.equal(#env.heard, 1, 'the changes heard')
  expect.equal(env.heard[1].seat, env.left, 'the seat heard')
  expect.equal(env.heard[1].sink, env.sink, 'the sink heard')
  expect.raises(function()
    env.heard[1].seat = env.right
  end, nil, 'a change is frozen')
  expect.equal(env.focus:setFocus(env.owner, { seat = env.left, sink = env.otherSink }), grant, 'the moved grant')
  expect.equal(env.left.focus, env.otherSink, 'the native focus after the move')
  expect.equal(select(2, env.focus:focused()), env.otherSink, 'the focused sink')
  expect.equal(env.focus:setFocus(env.owner, { seat = env.left, sink = env.otherSink }), grant, 'an unchanged grant')
  expect.equal(#env.heard, 2, 'a grant that changes nothing is not announced')
  env.session:close()
end)

test('another seat is another grant, and disposing it takes its focus back', function()
  local env = start()
  local grant = env.focus:setFocus(env.owner, { seat = env.left, sink = env.sink })
  local rightGrant = env.focus:setFocus(env.owner, { seat = env.right, sink = env.sink })
  expect.truthy(rightGrant ~= grant, 'a grant of its own')
  expect.equal(env.focus:focused(), env.right, 'the most recent grant is answered')
  rightGrant:dispose()
  expect.equal(env.right.focus, nil, 'the disposed grant takes its focus back')
  expect.equal(env.focus:focused(), nil, 'the focused seat after the disposal')
  expect.equal(env.left.focus, env.sink, 'the other seat keeps its focus')
  env.session:close()
end)

test('a nil sink withdraws a grant without ending it', function()
  local env = start()
  local grant = env.focus:setFocus(env.owner, { seat = env.left, sink = env.sink })
  expect.equal(env.focus:setFocus(env.owner, { seat = env.left }), grant, 'the withdrawn grant')
  expect.equal(env.left.focus, nil, 'the native focus after the withdrawal')
  expect.equal(env.focus:focused(), nil, 'the focused seat after the withdrawal')
  expect.equal(env.focus:setFocus(env.owner, { seat = env.left, sink = env.sink }), grant, 'the grant again')
  expect.equal(env.left.focus, env.sink, 'the native focus given again')
  env.session:close()
end)

test('a later holder of a seat keeps it when the earlier ends, and loses it when it unloads', function()
  local env = start()
  local grant = env.focus:setFocus(env.owner, { seat = env.left, sink = env.sink })
  env.focus:setFocus(env.other, { seat = env.left, sink = env.otherSink })
  expect.equal(env.left.focus, env.otherSink, 'the later grant decides')
  grant:dispose()
  expect.equal(env.left.focus, env.otherSink, 'an earlier grant that gave the seat away takes nothing back')
  env.second:disable()
  expect.equal(env.left.focus, nil, 'an unloading owner takes its focus back')
  expect.equal(env.focus:focused(), nil, 'the focused seat after the unload')
  env.session:close()
end)

test('a listener that raises is reported, and the listeners after it still run', function()
  local env = start()
  local after = 0
  env.focus:onChanged(env.owner, {
    run = function()
      error 'focus listener failure'
    end,
  })
  env.focus:onChanged(env.owner, {
    run = function()
      after += 1
    end,
  })
  env.focus:setFocus(env.owner, { seat = env.right, sink = env.sink })
  expect.equal(after, 1, 'the listener after a raising one')
  local reported = env.native.events.reported
  expect.equal(#reported, 1, 'the reports')
  expect.truthy(reported[1].message:find('focus listener failure', 1, true), 'the reported failure')
  env.session:close()
end)

return test

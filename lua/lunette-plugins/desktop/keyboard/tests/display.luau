local testing = require '@testing'
local expect = testing.expect
local fixture = require './support/display'
local test = testing.suite()

test('field focus automatically shows one keyboard and field changes retain its pose', function()
  local env = fixture.start()
  expect.equal(fixture.boardCount(env), 0, 'the keyboard is lazy')
  expect.truthy(env.first:focus())
  local board = fixture.shown(env)
  expect.truthy(board, 'field focus offers a keyboard')
  expect.equal(fixture.boardCount(env), 1, 'one real keyboard registration')
  local pose = lovr.math.newMat4():translate(3, 2, 1)
  board:setPose(pose)
  expect.truthy(env.second:focus())
  expect.equal(fixture.shown(env), board, 'field changes reuse the keyboard')
  expect.equal(vector.pack(board.pose:getPosition()), vector.pack(3, 2, 1), 'field changes do not place again')
  expect.truthy(env.second:blur())
  expect.equal(fixture.shown(env), nil, 'ending editing hides the automatic keyboard')
  expect.equal(fixture.boardCount(env), 1, 'hiding retains the real keyboard')
  env.session:close()
end)

test('automatic focus hides on a native route but manual visibility is retained', function()
  local env = fixture.start()
  expect.truthy(env.first:focus())
  local board = fixture.shown(env)
  local native = env.nativeTarget()
  expect.truthy(native:focus())
  expect.equal(fixture.shown(env), nil, 'a native route ends automatic visibility')
  expect.truthy(env.display.service:show())
  expect.equal(fixture.shown(env), board, 'manual show reuses the keyboard')
  expect.truthy(env.second:focus())
  expect.truthy(native:focus())
  expect.equal(fixture.shown(env), board, 'manual visibility survives leaving a field')
  expect.truthy(env.display.service:hide())
  expect.equal(env.focus:focused(), native, 'hide never blurs a native route')
  expect.truthy(native:blur())
  expect.equal(fixture.boardCount(env), 1)
  env.session:close()
end)

test('manual show is idempotent and only a hidden to visible transition places the keyboard', function()
  local env = fixture.start()
  local display = env.display.service
  expect.truthy(display:show())
  local board = fixture.shown(env)
  board:setPose(lovr.math.newMat4():translate(4, 3, 2))
  for _ = 1, 3 do
    expect.truthy(display:show())
    expect.equal(vector.pack(board.pose:getPosition()), vector.pack(4, 3, 2))
  end
  expect.truthy(display:toggle())
  expect.falsy(display:isVisible())
  expect.truthy(display:toggle())
  expect.equal(fixture.shown(env), board)
  expect.truthy(vector.pack(board.pose:getPosition()) ~= vector.pack(4, 3, 2), 'a fresh show places again')
  env.session:close()
end)

test('public hide clears editing before callbacks and preserves the draft for a fresh focus', function()
  local env = fixture.start()
  local display = env.display.service
  expect.truthy(env.first:focus())
  local board = fixture.shown(env)
  expect.truthy(board:typeText '!')
  local changes = {}
  display:onChanged(env.display.context, {
    run = function(change)
      changes[#changes + 1] = change
      expect.truthy(table.isfrozen(change), 'visibility changes are frozen')
    end,
  })
  expect.truthy(display:hide())
  expect.equal(env.focus:focused(), nil, 'public hide blurs its exact local target')
  expect.equal(env.first:value(), 'draft!')
  expect.truthy(env.first:focus(), 'a fresh field focus resumes editing')
  expect.equal(fixture.shown(env), board)
  expect.truthy(board:typeText '?')
  expect.equal(env.first:value(), 'draft!?')
  expect.equal(changes[1].reason, 'hide')
  expect.equal(changes[2].reason, 'show')
  expect.truthy(changes[2].revision > changes[1].revision)
  expect.equal(changes[2].target, env.focus:focused())
  env.session:close()
end)

test('display replacement leaves retained focus alone until a new live change', function()
  local env = fixture.start()
  expect.truthy(env.first:focus())
  local target, board, old = env.focus:focused(), fixture.shown(env), env.rawDisplay
  expect.truthy(board:typeText '!')
  env.session.instances['desktop/keyboard']:disable()
  expect.truthy(old.dead)
  expect.truthy(board.dead)
  expect.falsy(old:show())
  expect.falsy(old:hide())
  expect.falsy(old:toggle())
  expect.falsy(old:isVisible())
  expect.equal(env.focus:focused(), target, 'display shutdown does not blur the field')
  env.session.instances['desktop/keyboard']:enable()
  expect.truthy(env.display.service ~= old)
  expect.falsy(env.display.service:isVisible(), 'activation does not replay retained focus')
  expect.equal(fixture.boardCount(env), 0, 'replacement is still lazy')
  expect.truthy(env.first:blur())
  expect.truthy(env.first:focus())
  local replacement = fixture.shown(env)
  expect.truthy(replacement and replacement ~= board)
  expect.truthy(replacement:typeText '?')
  expect.equal(env.first:value(), 'draft!?', 'the retained draft resumes on fresh focus')
  expect.raises(function()
    old:onChanged(env.display.context, { run = function() end })
  end, 'cleanup%-only')
  env.session:close()
end)

test('listener disposal and observer failure do not skip later listeners or cleanup', function()
  local env = fixture.start()
  local display = env.display.service
  local first, second = 0, 0
  local disposed = display:onChanged(env.display.context, {
    run = function()
      first += 1
    end,
  })
  disposed:dispose()
  display:onChanged(env.display.context, {
    run = function()
      error 'display observer defect'
    end,
  })
  display:onChanged(env.display.context, {
    run = function()
      second += 1
    end,
  })
  expect.truthy(display:show())
  expect.equal(first, 0)
  expect.equal(second, 1, 'a failing listener does not skip a later observer')
  local reports = env.session.native.events.reported
  expect.equal(#reports, 1)
  expect.truthy(reports[1].message:find('display observer defect', 1, true))
  expect.truthy(reports[1].message:find('testing/observer', 1, true), 'the report names the listener owner')
  expect.equal(#testing.takeReports(), 0)
  env.display.instance:disable()
  expect.truthy(display:hide())
  expect.equal(second, 1, 'owner shutdown disposes all listeners')
  env.session.instances['desktop/keyboard']:disable()
  expect.truthy(env.rawDisplay.dead)
  expect.equal(fixture.boardCount(env), 0)
  env.session:close()
end)

test('keyboard provider recovery releases stale callbacks while a dead board remains retained', function()
  local env = fixture.start()
  expect.truthy(env.first:focus())
  local board, target = fixture.shown(env), env.focus:focused()
  local weak = setmetatable({}, { __mode = 'v' })
  do
    local token = { called = false }
    weak.token = token
    local callback = function()
      token.called = true
    end
    weak.callback = callback
    env.rawDisplay:onChanged(env.display.context, { run = callback })
  end
  env.session.instances.keyboard:disable()
  expect.truthy(board.dead)
  expect.falsy(board:typeText 'stale')
  expect.equal(env.focus:focused(), target, 'keyboard loss does not blur the retained widget')
  collectgarbage 'collect'
  collectgarbage 'collect'
  expect.equal(weak.callback, nil, 'the dead board cannot retain display listener callbacks')
  expect.equal(weak.token, nil, 'callback captures are released while the board remains retained')
  env.session.instances.keyboard:enable()
  expect.falsy(env.display.service:isVisible(), 'keyboard recovery does not replay retained focus')
  expect.equal(fixture.boardCount(env), 0)
  expect.truthy(env.first:blur())
  expect.truthy(env.first:focus())
  expect.truthy(fixture.shown(env) ~= board)
  env.session:close()
end)

return test

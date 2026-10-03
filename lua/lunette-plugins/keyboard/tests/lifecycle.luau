-- Covers the default keyboard reaching the focused sink, and what ends with its owner: the keyboard, the focus,
-- the held modifiers, and a failing release quarantining the owner rather than the provider.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local keyboardContract = require '@lunette-contracts/keyboard'
local focusContract = require '@lunette-contracts/focus'

local test = testing.suite()

-- The focus and keyboard providers in a runtime of their own, and a consumer of both.
local function start()
  local env = { session = testing.start { 'focus', 'keyboard' } }
  env.consumer = env.session:use(plugin.define {
    name = 'keyboard-lifecycle-test',
    requires = { keyboard = keyboardContract.capability, focus = focusContract.capability },
    init = function(context)
      env.service, env.owner = context:require(keyboardContract.capability), context
      env.focus = context:require(focusContract.capability)
    end,
  })
  return env
end

-- A seat whose keycode 30 types q, or Q under shift, and a sink recording what reaches it.
local function focusTarget()
  local sent = {}
  local seat = { dead = false }
  function seat:characterFor(code, held)
    if code == 30 then
      return if table.find(held, 'shift') then 'Q' else 'q'
    end
    return nil
  end
  function seat:symbolFor()
    return 123
  end
  function seat:strokeFor(text)
    if text == 'q' then
      return { keycode = 30, modifiers = {} }
    elseif text == 'Q' then
      return { keycode = 30, modifiers = { 'shift' } }
    end
    return nil
  end
  function seat:setFocus(target)
    self.focus = target
    return true
  end
  local sink = { dead = false }
  function sink:modifiers(held, actual)
    assert(actual == seat, 'the modifiers reach the focused seat')
    sent[#sent + 1] = { 'modifiers', table.clone(held) }
    return true
  end
  function sink:key(code, pressed, actual)
    assert(actual == seat, 'the key reaches the focused seat')
    sent[#sent + 1] = { 'key', code, pressed }
    return true
  end
  function sink:typeText(text, actual)
    assert(actual == seat, 'the text reaches the focused seat')
    sent[#sent + 1] = { 'text', text }
    return true
  end
  return seat, sink, sent
end

test(
  'the keyboard types into the focused sink, and its owner unloading ends it, the focus, and the modifiers',
  function()
    testing.native()
    local env = start()
    local seat, sink, sent = focusTarget()
    env.focus:setFocus(env.owner, { seat = seat, sink = sink })
    expect.equal(seat.focus, sink, 'the focused sink')
    local board = env.service:new(env.owner)
    local q
    for _, key in ipairs(board:keys()) do
      if key.code == 30 then
        q = key
      end
    end
    expect.equal(q.legend, 'q', "a legend comes from the focused seat's layout")

    board:pressKey(42)
    board:pressKey(30)
    expect.equal(sent[1][2][1], 'shift', 'shift latches for the next key')
    expect.truthy(sent[2][3] == true and sent[3][3] == false, 'the key is pressed and released')
    expect.equal(#board:modifiers(), 0, 'the latch clears')
    board:pressKey(58)
    board:pressKey(30)
    expect.equal(board:modifiers()[1], 'capsLock', 'caps lock stays')

    table.clear(sent)
    board:typeText 'qüßQ'
    expect.truthy(sent[4][1] == 'text' and sent[4][2] == 'üß', 'what the layout cannot stroke is typed as text')

    env.consumer:disable()
    expect.truthy(board.dead, 'the keyboard ends with its owner')
    expect.equal(seat.focus, nil, 'the focus the owner held ends with it')
    expect.truthy(sent[#sent][1] == 'modifiers' and #sent[#sent][2] == 0, 'the held modifiers are released')
    local count = #sent
    expect.falsy(board:destroy(), 'a second destroy')
    expect.equal(#sent, count, 'a second destroy sends nothing')
    expect.raises(function()
      env.service:new(env.owner)
    end, nil, 'an unloaded owner')
    env.session:close()
  end
)

test('a destroyed keyboard is not retained, and an owner from another runtime is refused', function()
  testing.native()
  local env, other = start(), start()
  local retained = setmetatable({}, { __mode = 'v' })
  do
    local board = env.service:new(env.owner)
    retained.board = board
    expect.truthy(board:destroy(), 'the first destroy')
    expect.falsy(board:destroy(), 'a second destroy')
  end
  testing.collect()
  expect.equal(retained.board, nil, 'the destroyed keyboard is collected')

  expect.raises(function()
    env.service:new(other.owner)
  end, nil, 'an owner from another runtime')
  env.session.instances.keyboard:disable()
  expect.truthy(other.service:new(other.owner), "another runtime's provider is unaffected")
  other.session:close()
  env.session:close()
end)

test('a failing keyboard release quarantines its owner, not the provider', function()
  testing.native()
  local env = start()
  local seat = { dead = false }
  function seat:setFocus(target)
    self.focus = target
    return true
  end
  local failing, failedReleases = false, 0
  local sink = { dead = false }
  function sink:modifiers()
    if failing then
      failedReleases += 1
      error 'native keyboard release failed'
    end
    return true
  end
  function sink:key()
    return true
  end
  env.focus:setFocus(env.owner, { seat = seat, sink = sink })
  local board = env.service:new(env.owner)
  board:pressKey(30)
  failing = true

  env.consumer:disable()
  expect.truthy(failedReleases == 1 and board.dead, 'the release ran once')
  expect.equal(env.consumer:state(), 'quarantined', 'the failing owner')
  expect.equal(env.session.instances.keyboard:state(), 'active', 'the keyboard provider')
  local reports = testing.takeReports()
  expect.equal(#reports, 1, 'the reported failures')
  expect.truthy(reports[1]:find('native keyboard release failed', 1, true), 'the reported failure')

  local survivor = env.session:observe(keyboardContract.capability)
  expect.truthy(survivor.service:new(survivor.context), 'the keyboard provider serves another owner')
  env.session:close()
end)

return test

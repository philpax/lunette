local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local keyboardContract = require '@lunette-contracts/keyboard'
local focusContract = require '@lunette-contracts/focus'

local test = testing.suite()

local function start()
  local env = { session = testing.start { 'theme', 'focus', 'keyboard' } }
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

local function focusTarget()
  local sent = {}
  local seat = { id = 1, dead = false }
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
  local sink = { id = 1, domain = 'window', dead = false }
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
    env.focus:register(env.owner, { kind = 'native', seat = seat, sink = sink }):focus()
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
    expect.falsy(board:typeText 'qüßQ', 'unrepresentable window text is refused')
    expect.equal(#sent, 4, 'the representable prefix is one complete native activation')
    expect.truthy(sent[2][1] == 'key' and sent[2][2] == 30, 'the keymap strokes the representable prefix')
    for _, event in sent do
      expect.truthy(event[1] ~= 'text', 'the keyboard does not fabricate committed window text')
    end

    env.consumer:disable()
    expect.truthy(board.dead, 'the keyboard ends with its owner')
    expect.equal(seat.focus, nil, 'the focus the owner held ends with it')
    expect.equal(#board:modifiers(), 0, 'destroy clears the keyboard modifier state')
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

test('a failed native inverse refuses later keyboard activations and keeps the provider active', function()
  local native = testing.native()
  local env = start()
  local seat = { id = 1, dead = false }
  function seat:setFocus(target)
    self.focus = target
    return true
  end
  local failedReleases, presses = 0, 0
  local sink = { id = 1, domain = 'window', dead = false }
  function sink:modifiers()
    return true
  end
  function sink:key(_code, down)
    if not down then
      failedReleases += 1
      error 'native keyboard release failed'
    end
    presses += 1
    return true
  end
  env.focus:register(env.owner, { kind = 'native', seat = seat, sink = sink }):focus()
  local board = env.service:new(env.owner)
  board:pressKey(42)
  expect.falsy(board:pressKey(30), 'the activation whose inverse fails')
  expect.equal(#board:modifiers(), 0, 'the failed activation still consumes the latch')
  expect.falsy(board:pressKey(31), 'the unsafe source refuses subsequent input')
  expect.equal(presses, 1, 'the refused activation sends no key')
  expect.equal(failedReleases, 1, 'the inverse is attempted once')
  expect.equal(env.session.instances.keyboard:state(), 'active', 'the keyboard provider')
  local reports = native.events.reported
  expect.equal(#reports, 1, 'the reported failures')
  expect.truthy(reports[1].message:find('native keyboard release failed', 1, true), 'the reported failure')
  expect.truthy(board:destroy(), 'destroy commits even when the source is unsafe')
  expect.truthy(board.dead)
  expect.falsy(board:destroy())
  env.session:close()
end)

return test

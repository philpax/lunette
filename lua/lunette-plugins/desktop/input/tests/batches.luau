local testing = require '@testing'
local physical = require './support/physical'
local expect = testing.expect
local test = physical.suite()

local function changeDuringBinding(f, method, target, consume)
  return f.frame[method](f.frame, f.frameOwner, {
    phase = 'binding',
    run = function()
      expect.truthy(target:focus(), 'the binding changes the focused route')
      return consume
    end,
  })
end

test('a consumed printable binding blocks all physical text until the next batch without moving focus', function()
  for _, destination in ipairs { 'local', 'host', 'window' } do
    local f = physical.boot(if destination == 'local' then nil else destination)
    local target = if destination == 'local' then f:localTarget 'field' else f.nativeTarget
    expect.truthy(target:focus(), 'the route acquires focus')
    local revision = f.focus:revision()
    local binding = f.frame:onKey(f.frameOwner, {
      phase = 'binding',
      run = function(event)
        return event.key == 'q'
      end,
    })
    f:pair('q', 'q')
    local batch = f.batch
    binding:dispose()
    lovr.textinput('later', 108)
    expect.equal(f.focus:revision(), revision, 'the binding leaves focus unchanged')
    expect.equal(f.batch, batch, 'blocking text does not open another batch')
    expect.equal(f:trace(), '', 'neither the consumed key nor any same-batch text reaches the route')
    f:nextBatch()
    expect.equal(f.batch, batch + 1, 'the next update opens a fresh batch')
    lovr.textinput('q', 113)
    expect.equal(
      f:trace(),
      if destination == 'local'
        then 'field:text:q'
        elseif destination == 'host' then 'native-text:q'
        else 'resolve:q|mods:|key:16:down|key:16:up|mods:',
      'fresh independent text reaches the unchanged route'
    )
    f:close()
  end
end)

test('input recovery observes blocked metadata and does not restore same-batch text', function()
  local f = physical.boot()
  local target = f:localTarget 'field'
  expect.truthy(target:focus(), 'the field acquires focus')
  local binding = f.frame:onKey(f.frameOwner, {
    phase = 'binding',
    run = function()
      return true
    end,
  })
  f:pair('q', 'q')
  binding:dispose()
  f.session.instances['desktop/input']:disable()
  f.session.instances['desktop/input']:enable()
  lovr.textinput('later', 108)
  expect.equal(f:trace(), '', 'a replacement physical source cannot accept a blocked batch')
  f:nextBatch()
  lovr.textinput('é🙂', 233)
  expect.equal(f:trace(), 'field:text:é🙂', 'the next boundary restores eligibility')
  f:close()
end)

test('a raising key binding falls through to physical delivery without blocking text', function()
  local f = physical.boot()
  local target = f:localTarget 'field'
  expect.truthy(target:focus(), 'the field acquires focus')
  f.frame:onKey(f.frameOwner, {
    phase = 'binding',
    run = function()
      error 'fixture binding failure'
    end,
  })
  f:pair('q', 'q')
  expect.equal(f:trace(), 'field:key:16:physical::false|field:text:q', 'a raising binding consumes nothing')
  local reports = f.native.events.reported
  expect.equal(#reports, 1, 'the binding failure is reported')
  expect.truthy(reports[1].message:find('fixture binding failure', 1, true))
  table.clear(reports)
  f:close()
end)

test('a consumed text binding affects only that callback and does not guess a key association', function()
  local f = physical.boot()
  local target = f:localTarget 'field'
  expect.truthy(target:focus(), 'the field acquires focus')
  f.frame:onText(f.frameOwner, {
    phase = 'binding',
    run = function(event)
      return event.text == 'q'
    end,
  })
  f:pair('q', 'q')
  lovr.textinput('é🙂', 233)
  expect.equal(
    f:trace(),
    'field:key:16:physical::false|field:text:é🙂',
    'later committed text remains eligible in the same batch'
  )
  f:close()
end)

test('the lazy key batch snapshots focus before binding-phase local and native focus changes', function()
  for _, destination in ipairs { 'local', 'native' } do
    for _, consume in ipairs { false, true } do
      local f = physical.boot 'host'
      local previous = f:localTarget 'previous'
      local nextTarget = if destination == 'local' then f:localTarget 'next' else f.nativeTarget
      expect.truthy(previous:focus(), 'the original field acquires focus')
      local binding = changeDuringBinding(f, 'onKey', nextTarget, consume)
      f:pair('q', 'q')
      lovr.textinput('stale', 115)
      expect.equal(f:trace(), '', 'neither stale key nor text reaches the replacement route')
      binding:dispose()
      f:nextBatch()
      lovr.textinput('é🙂', 233)
      expect.equal(
        f:trace(),
        if destination == 'local' then 'next:text:é🙂' else 'native-text:é🙂',
        'the next batch accepts independent text'
      )
      f:close()
    end
  end
end)

test('a text-first batch observes focus before a binding changes the receiver', function()
  local f = physical.boot()
  local previous, nextTarget = f:localTarget 'previous', f:localTarget 'next'
  expect.truthy(previous:focus(), 'the original field acquires focus')
  local binding = changeDuringBinding(f, 'onText', nextTarget, false)
  lovr.textinput('stale', 115)
  expect.equal(f:trace(), '', 'text-first focus changes refuse the old batch')
  binding:dispose()
  f:nextBatch()
  lovr.textinput('é🙂', 233)
  expect.equal(f:trace(), 'next:text:é🙂', 'fresh text-first delivery after an update')
  f:close()
end)

test('multiple callbacks share a batch and an external route change refuses text until the next one', function()
  local f = physical.boot()
  local previous, nextTarget = f:localTarget 'previous', f:localTarget 'next'
  expect.truthy(previous:focus(), 'the original field acquires focus')
  f:pair('q', 'q')
  local first = f.batch
  f:pair('q', 'é🙂', true)
  expect.equal(f.batch, first, 'both key/text pairs share one numeric batch')
  expect.equal(type(first), 'number', 'the live frame contract uses numeric event batches')
  expect.truthy(nextTarget:focus(), 'an external callback moves focus')
  lovr.textinput('stale', 115)
  expect.equal(
    f:trace(),
    'previous:key:16:physical::false|previous:text:q|previous:key:16:physical::true|previous:text:é🙂',
    'no text from the old batch reaches the new receiver'
  )
  f:nextBatch()
  expect.equal(f.batch, first + 1, 'the update advances the batch')
  lovr.textinput('é🙂', 233)
  expect.equal(f.log[#f.log], 'next:text:é🙂', 'the new receiver accepts the new batch')
  f:close()
end)

test('input recovery immediately observes an existing batch before registering delivery handlers', function()
  local f = physical.boot()
  local consume = true
  local target = f:localTarget('field', {
    key = function()
      return consume
    end,
  })
  expect.truthy(target:focus(), 'the field acquires focus')
  f:pair('q', 'q')
  f.session.instances['desktop/input']:disable()
  f:nextBatch()
  f.session.instances['desktop/input']:enable()
  consume = false
  lovr.textinput('é🙂', 233)
  expect.equal(f:trace(), 'field:key:16:physical::false|field:text:é🙂', 'recovery initializes the current batch')
  f:close()
end)

test('input owns one physical source and releases it across disable and recovery', function()
  local f = physical.boot()
  local function sourceCount()
    return f.focus:inspect().state.sourceCount
  end
  expect.equal(sourceCount(), 1, 'one source for the active input consumer')
  f.session.instances['desktop/input']:disable()
  expect.equal(sourceCount(), 0, 'the disabled input releases its source')
  f.session.instances['desktop/input']:enable()
  expect.equal(sourceCount(), 1, 'recovery creates exactly one new source')
  f:close()
end)

return test.result

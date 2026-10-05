local testing = require '@testing'
local vocabulary = require '@lunette-contracts/vocabulary'
local fixture = require './support/protocol'
local expect = testing.expect
local test = testing.suite()

test('surface capture preserves every button and real pointer identity without legacy duplication', function()
  local f = fixture()
  local first, second = f:pointer(), f:pointer()
  local target = f:surface 'plate'
  local held = {}
  for _, button in ipairs(vocabulary.POINTER_BUTTONS) do
    held[button] = true
  end
  f:update(first, { target }, { buttons = held })
  f:update(second, { target }, { buttons = { left = true } })
  for _, button in ipairs(vocabulary.POINTER_BUTTONS) do
    local pressed = f:matching('press', first, target, button)
    expect.equal(#pressed, 1, 'one press for the actual button')
    expect.truthy(pressed[1].captured and pressed[1].inside, 'press starts inside its capture')
  end
  expect.equal(#f:matching('press', second, target, 'left'), 1, 'the second pointer has its own capture')
  f:update(first, { target })
  expect.equal(#f:matching('release', first, target), #vocabulary.POINTER_BUTTONS, 'each button releases once')
  expect.equal(#f:matching('release', second, target), 0, 'the first pointer cannot release the second')
  f:update(second, { target })
  expect.equal(#f:matching('release', second, target, 'left'), 1, 'the second releases its own button')
  expect.equal(f.legacy, 0, 'a protocol surface receives no legacy callbacks')
  f:close()
end)

test('captured motion projects outside bounds and release reaches the original surface', function()
  local f = fixture()
  local pointer = f:pointer()
  local original, replacement = f:surface 'original', f:surface 'replacement'
  function replacement:raycast(origin)
    if origin.x > 0.5 then
      return 0.25, 0.5, 0.5
    end
    return nil, nil, nil
  end
  f:update(pointer, { original, replacement }, { buttons = { left = true } })
  f:update(pointer, { original, replacement }, { x = 2, buttons = { left = true } })
  local moved = f:matching('move', pointer, original, 'left')
  expect.truthy(#moved > 0, 'the captured surface receives motion')
  expect.near(moved[#moved].x, 2.5, 1e-6, 'unbounded projection is not clamped')
  expect.falsy(moved[#moved].inside, 'the ray is outside the original surface')
  expect.equal(#f:matching('cancel', pointer, original), 0, 'hover leave does not cancel capture')
  f:update(pointer, { original, replacement }, { x = 2 })
  local released = f:matching('release', pointer, original, 'left')
  expect.equal(#released, 1, 'release reaches the surface pressed earlier')
  expect.falsy(released[1].inside, 'an outside release cannot activate an inside-only control')
  expect.equal(#f:matching('release', pointer, replacement), 0, 'hover does not redirect release')
  f:close()
end)

test('dead and withdrawn surfaces cancel while a held trigger cannot reacquire a replacement', function()
  for _, cause in ipairs { 'surface-dead', 'surface-withdrawn' } do
    local f = fixture()
    local pointer, target = f:pointer(), f:surface 'plate'
    f:update(pointer, { target }, { buttons = { left = true } })
    local replacement = f:surface 'replacement'
    if cause == 'surface-dead' then
      target.dead = true
    end
    f:update(pointer, { replacement }, { buttons = { left = true } })
    local cancelled = f:matching('cancel', pointer, target, 'left')
    expect.equal(#cancelled, 1, 'the old capture cancels exactly once')
    expect.equal(cancelled[1].reason, cause, 'the surface loss reason')
    expect.equal(#f:matching('press', pointer, replacement), 0, 'held input does not acquire a replacement')
    f:update(pointer, { replacement })
    f:update(pointer, { replacement }, { buttons = { left = true } })
    expect.equal(#f:matching('press', pointer, replacement), 1, 'a new edge acquires the replacement')
    f:close()
  end
end)

test('surface death during motion cancels every capture before an all-up frame can release', function()
  local f = fixture()
  local pointer, target = f:pointer(), f:surface 'plate'
  f:update(pointer, { target }, { buttons = { left = true, right = true } })
  local record = target.onPointer
  function target:onPointer(event)
    record(self, event)
    if event.kind == 'move' then
      self.dead = true
    end
  end
  f:update(pointer, { target })
  expect.equal(#f:matching('release', pointer, target), 0, 'a dead surface cannot receive an activating release')
  local cancelled = f:matching('cancel', pointer, target)
  expect.equal(#cancelled, 2, 'both captures cancel in the same update')
  for _, event in ipairs(cancelled) do
    expect.equal(event.reason, 'surface-dead', 'motion death is surface death')
  end
  f:close()
end)

for _, shared in ipairs { true, false } do
  local relation = if shared then 'the same' else 'another'
  test('queued releases cancel after the first callback kills ' .. relation .. ' captured surface', function()
    local f = fixture()
    local pointer, first = f:pointer(), f:surface 'first'
    local later = if shared then first else f:surface 'later'
    local record = first.onPointer
    function first:onPointer(event)
      record(self, event)
      if event.kind == 'release' and event.button == 'left' then
        later.dead = true
      end
    end
    pointer:hover(first)
    pointer:setButton { button = 'left', pressed = true, surface = first }
    pointer:hover(later)
    pointer:setButton { button = 'right', pressed = true, surface = later }
    f:update(pointer, { first, later })
    expect.equal(#f:matching('release', pointer, first, 'left'), 1, 'the first release runs before surface death')
    expect.equal(#f:matching('release', pointer, later, 'right'), 0, 'a queued release cannot activate a dead surface')
    local cancelled = f:matching('cancel', pointer, later, 'right')
    expect.equal(#cancelled, 1, 'the later button cancels exactly once')
    expect.equal(cancelled[1].reason, 'surface-dead', 'the queued terminal event uses current surface liveness')
    pointer:destroy()
    expect.equal(#f:matching('cancel', pointer, later, 'right'), 1, 'cleanup does not repeat a detached terminal event')
    f:close()
  end)
end

for _, cause in ipairs { 'pointer-destroyed', 'tracking-loss' } do
  test('queued releases retain ' .. cause .. ' while every native inverse runs', function()
    local f = fixture()
    local pointer, target = f:pointer(), f:surface 'plate'
    local nativeReleases = {}
    local sink = {
      dead = false,
      domain = 'host',
      monitor = { id = 'queued-release-cleanup' },
      focus = function()
        return true
      end,
      button = function(_self, button, down)
        if not down then
          nativeReleases[#nativeReleases + 1] = button
          error('fixture queued native release failure ' .. button)
        end
      end,
    }
    local record = target.onPointer
    function target:onPointer(event)
      record(self, event)
      if event.kind == 'release' and event.button == 'left' then
        if cause == 'pointer-destroyed' then
          pointer:destroy()
        else
          pointer:withdraw()
        end
        error 'fixture first release failure'
      elseif event.kind == 'cancel' and event.button == 'right' then
        error 'fixture queued cancel failure'
      end
    end
    pointer:hover(target)
    for _, button in ipairs { 'left', 'right' } do
      pointer:setButton { button = button, pressed = true, surface = target }
    end
    for _, button in ipairs { 'middle', 'back' } do
      pointer:setButton { button = button, pressed = true, sink = sink }
    end
    expect.raises(function()
      f:update(pointer, { target })
    end, 'fixture first release failure', 'terminal callback failures reach the caller')
    expect.equal(#f:matching('release', pointer, target, 'left'), 1, 'the first release runs before invalidation')
    expect.equal(#f:matching('release', pointer, target, 'right'), 0, 'invalidation prevents the later activation')
    local cancelled = f:matching('cancel', pointer, target, 'right')
    expect.equal(#cancelled, 1, 'the later queued button cancels exactly once')
    expect.equal(cancelled[1].reason, cause, 'the pointer invalidation reason survives nested cleanup')
    expect.equal(table.concat(nativeReleases, '+'), 'middle+back', 'every queued native inverse is attempted')
    pointer:destroy()
    expect.equal(#nativeReleases, 2, 'native cleanup does not repeat cleared presses')
    expect.equal(#f:matching('cancel', pointer, target, 'right'), 1, 'pointer cleanup does not repeat cancellation')
    f:close()
  end)
end

test('queued targeted cancellation preserves unrelated surfaces and new gestures', function()
  local f = fixture()
  local pointer, first, later, unaffected = f:pointer(), f:surface 'first', f:surface 'later', f:surface 'unaffected'
  local record = first.onPointer
  function first:onPointer(event)
    record(self, event)
    if event.kind == 'release' and event.button == 'left' then
      pointer:cancel(later, 'hidden')
      pointer:hover(later)
      pointer:setButton { button = 'right', pressed = true, surface = later }
    end
  end
  pointer:hover(first)
  pointer:setButton { button = 'left', pressed = true, surface = first }
  pointer:hover(later)
  pointer:setButton { button = 'right', pressed = true, surface = later }
  pointer:hover(unaffected)
  pointer:setButton { button = 'middle', pressed = true, surface = unaffected }
  f:update(pointer, { first, later, unaffected })
  expect.equal(#f:matching('release', pointer, later, 'right'), 0, 'cancellation prevents the queued activation')
  local cancelled = f:matching('cancel', pointer, later, 'right')
  expect.equal(#cancelled, 1, 'the detached targeted capture cancels exactly once')
  expect.equal(cancelled[1].reason, 'hidden', 'targeted cancellation retains its explicit reason')
  expect.equal(#f:matching('release', pointer, unaffected, 'middle'), 1, 'an unrelated capture still releases')
  expect.equal(#f:matching('cancel', pointer, unaffected), 0, 'targeted cancellation does not affect another surface')
  expect.equal(#f:matching('press', pointer, later, 'right'), 2, 'the callback starts a fresh gesture')
  pointer:setButton { button = 'right', pressed = false }
  expect.equal(#f:matching('release', pointer, later, 'right'), 1, 'the new capture survives queued cancellation')
  pointer:destroy()
  expect.equal(#f:matching('cancel', pointer, later, 'right'), 1, 'cleanup cannot repeat the old terminal callback')
  f:close()
end)

test('queued releases survive harmless reentry and preserve new callback captures', function()
  local f = fixture()
  local pointer, original, replacement = f:pointer(), f:surface 'original', f:surface 'replacement'
  local record = original.onPointer
  function original:onPointer(event)
    record(self, event)
    if event.kind == 'release' and event.button == 'left' then
      pointer:focus(nil)
      pointer:hover(replacement)
      pointer:setButton { button = 'right', pressed = true, surface = replacement }
    end
  end
  pointer:hover(original)
  pointer:setButton { button = 'left', pressed = true, surface = original }
  pointer:setButton { button = 'right', pressed = true, surface = original }
  f:update(pointer, { original, replacement })
  expect.equal(#f:matching('release', pointer, original), 2, 'generation changes alone do not cancel queued releases')
  expect.equal(#f:matching('cancel', pointer, original), 0, 'harmless reentry is not pointer destruction')
  expect.equal(#f:matching('press', pointer, replacement, 'right'), 1, 'reentry captures a new gesture')
  pointer:setButton { button = 'right', pressed = false }
  expect.equal(#f:matching('release', pointer, replacement, 'right'), 1, 'the old queue does not clear the new capture')
  f:close()
end)

test('projection scroll and primitive release revalidate capture liveness', function()
  for _, boundary in ipairs { 'project', 'scroll', 'primitive' } do
    local f = fixture()
    local pointer, target = f:pointer(), f:surface 'plate'
    f:update(pointer, { target }, { buttons = { left = true, right = true } })
    if boundary == 'project' then
      local project = target.project
      function target:project(origin)
        self.dead = true
        return project(self, origin)
      end
      f:update(pointer, { target })
    elseif boundary == 'scroll' then
      local record = target.onPointer
      function target:onPointer(event)
        record(self, event)
        if event.kind == 'scroll' then
          self.dead = true
        end
      end
      f:update(pointer, { target }, { scrollY = 1 })
    else
      target.dead = true
      pointer:setButton { button = 'left', pressed = false }
      pointer:setButton { button = 'right', pressed = false }
    end
    expect.equal(#f:matching('release', pointer, target), 0, boundary .. ' cannot activate a dead capture')
    local cancelled = f:matching('cancel', pointer, target)
    expect.equal(#cancelled, 2, boundary .. ' cancels both captures')
    for _, event in ipairs(cancelled) do
      expect.equal(event.reason, 'surface-dead', 'the liveness reason is preserved')
    end
    f:close()
  end
end)

test('native target outages and false returns never select Lua input callbacks', function()
  for _, unavailable in ipairs { 'sink', 'seat', 'false-return' } do
    local f = fixture()
    local seat = require('@lunette').newSeat 'native-route'
    if unavailable == 'seat' then
      seat:destroy()
    end
    local pointer = f.service:newPointer(f.owner, { seat = seat })
    local target = f:surface 'native'
    local calls = { pointer = 0, button = 0, scroll = 0, leave = 0 }
    local sink = { dead = unavailable == 'sink', domain = 'host', monitor = { id = 'native-route' } }
    function sink:focus()
      return false
    end
    for _, method in ipairs { 'pointer', 'button', 'scroll', 'leave' } do
      sink[method] = function()
        calls[method] += 1
        return false
      end
    end
    function target:sink()
      return sink
    end
    f:update(pointer, { target }, { buttons = { left = true }, scrollY = 1 })
    f:update(pointer, {})
    expect.equal(#f.events, 0, unavailable .. ' never routes protocol events')
    expect.equal(f.legacy, 0, unavailable .. ' never routes legacy callbacks')
    if unavailable == 'false-return' then
      expect.truthy(
        calls.pointer > 0 and calls.button == 2 and calls.scroll == 1,
        'live false-return calls stay native'
      )
    else
      expect.equal(calls.pointer + calls.button + calls.scroll + calls.leave, 0, 'unavailable native target is inert')
    end
    f:close()
  end
end)

test('explicit surface cancellation preserves another pointer and requires a fresh press edge', function()
  local f = fixture()
  local first, second, target = f:pointer(), f:pointer(), f:surface 'plate'
  f:update(first, { target }, { buttons = { left = true } })
  f:update(second, { target }, { buttons = { left = true } })
  first:cancel(target, 'disabled')
  expect.equal(#f:matching('cancel', first, target), 1, 'the requested capture cancels')
  expect.equal(#f:matching('cancel', second, target), 0, 'another pointer is independent')
  f:update(first, { target }, { buttons = { left = true } })
  expect.equal(#f:matching('press', first, target), 1, 'the cancelled held button stays ineligible')
  f:update(second, { target })
  expect.equal(#f:matching('release', second, target), 1, 'the unaffected pointer releases normally')
  f:update(first, { target })
  f:update(first, { target }, { buttons = { left = true } })
  expect.equal(#f:matching('press', first, target), 2, 'an observed release permits another gesture')
  f:close()
end)

test('UI scroll applies pointer tuning once and does not invoke a native sink', function()
  local f = fixture()
  local pointer, target = f:pointer(), f:surface 'plate'
  f:update(pointer, { target }, { scrollX = 0.1, scrollY = 1, dt = 0.25 })
  local scrolled = f:matching('scroll', pointer, target)
  expect.equal(#scrolled, 1, 'one scroll event')
  expect.equal(scrolled[1].dx, 0, 'dead-zone x is zero')
  expect.near(scrolled[1].dy, -pointer.tuning.scrollScale * 0.25, 1e-6, 'scale, dt, and vertical inversion apply once')
  f:close()
end)

test('simultaneous native releases attempt every inverse even when the first raises', function()
  local f = fixture()
  local pointer, target = f:pointer(), f:surface 'native'
  local releases = {}
  local sink = {
    dead = false,
    domain = 'host',
    monitor = { id = 'native-release-matrix' },
    focus = function()
      return true
    end,
    pointer = function() end,
    scroll = function() end,
    leave = function() end,
    button = function(_self, button, down)
      if not down then
        releases[#releases + 1] = button
        error('fixture native release failure ' .. button)
      end
    end,
  }
  function target:sink()
    return sink
  end
  f:update(pointer, { target }, { buttons = { left = true, right = true } })
  expect.raises(function()
    f:update(pointer, { target })
  end, 'fixture native release failure', 'release failures reach the caller')
  expect.equal(table.concat(releases, '+'), 'left+right', 'all simultaneous native inverses run')
  pointer:destroy()
  expect.equal(#releases, 2, 'cleared gestures cannot release a second time during cleanup')
  f:close()
end)

test('native sink motion buttons and scaled scroll never duplicate surface protocol callbacks', function()
  local f = fixture()
  local pointer, target = f:pointer(), f:surface 'native'
  local moved, down, up, scrolled = 0, 0, 0, 0
  local sink = {
    dead = false,
    domain = 'host',
    monitor = { id = 'native-pointer-compatibility' },
    focus = function()
      return true
    end,
    pointer = function()
      moved += 1
    end,
    button = function(_self, button, pressed)
      expect.equal(button, 'right', 'the actual native button')
      if pressed then
        down += 1
      else
        up += 1
      end
    end,
    scroll = function(_self, dx, dy)
      scrolled += 1
      expect.equal(dx, 0, 'the scaled native horizontal delta')
      expect.near(dy, -pointer.tuning.scrollScale, 1e-6, 'the native vertical delta scales once')
    end,
    leave = function() end,
  }
  function target:sink()
    return sink
  end
  f:update(pointer, { target }, { buttons = { right = true }, scrollY = 1 })
  f:update(pointer, { target })
  expect.equal(down, 1, 'one native press')
  expect.equal(up, 1, 'one native release')
  expect.equal(scrolled, 1, 'one native scroll')
  expect.truthy(moved > 0, 'native motion remains available')
  expect.equal(#f.events, 0, 'a native sink receives no duplicate protocol events')
  expect.equal(f.legacy, 0, 'a native sink receives no duplicate legacy callbacks')
  f:close()
end)

test('surface cancellation is isolated when another button captures another surface', function()
  local f = fixture()
  local pointer, first, second = f:pointer(), f:surface 'first', f:surface 'second'
  pointer:hover(first)
  pointer:setButton { button = 'left', pressed = true, surface = first }
  pointer:hover(second)
  pointer:setButton { button = 'right', pressed = true, surface = second }
  function first:onPointer(event)
    if event.kind == 'cancel' then
      pointer:cancel(first, 'hidden')
    end
  end
  pointer:cancel(first, 'hidden')
  pointer:setButton { button = 'right', pressed = false }
  expect.equal(#f:matching('release', pointer, second, 'right'), 1, 'the other surface keeps its capture')
  expect.equal(#f:matching('cancel', pointer, second), 0, 'the other surface does not cancel')
  pointer:setButton { button = 'left', pressed = false }
  f:close()
end)

return test

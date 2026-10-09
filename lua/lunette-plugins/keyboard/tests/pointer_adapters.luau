local testing = require '@testing'
local expect = testing.expect
local focusContract = require '@lunette-contracts/focus'
local interaction = require '@lunette-contracts/interaction'
local keyboardContract = require '@lunette-contracts/keyboard'
local keyboard = require '@lunette-plugins/keyboard'
local focusProvider = require '@lunette-plugins/focus'
local plugin = require '@lunette-plugin'
local keys = require '@lunette-contracts/keys'
local theme = require '@lunette-contracts/theme'

local test = testing.suite()

local function fixture(kind, options)
  local native = testing.native()
  local f = { native = native, keys = {}, activations = {}, drawn = {}, events = {} }
  local definition
  if kind == 'tiny' then
    testing.host.useConfiguration 'examples/keyboard'
    definition = require 'tiny'
  else
    definition = keyboard.define {
      name = 'pointer-adapter-keyboard',
      rows = { { { code = keys.CODES.y }, { code = keys.CODES.n } } },
      layers = { alternate = { { { code = keys.CODES.enter } } } },
      style = { keyUnit = 0.05 },
      onKey = function(board, key, pointer, base)
        f.activations[#f.activations + 1] = pointer
        base(board, key, pointer)
      end,
      drawKey = function(_pass, key, state)
        f.drawn[key.code] = state.hovered
      end,
    }
  end
  local focusDefinition = plugin.define {
    name = 'pointer-adapter-focus',
    provides = { focus = focusContract.capability },
    init = function(context, _settings, publish)
      local service = focusProvider.build(context)
      local newSource = service.newSource
      service.newSource = function(self, owner, sourceOptions)
        f.source = newSource(self, owner, sourceOptions)
        return f.source
      end
      publish:provide(focusContract.capability, service)
    end,
  }
  f.session = testing.start {
    'theme',
    'drops',
    { id = 'focus', definition = focusDefinition },
    'interaction',
    { id = 'keyboard', definition = definition },
  }
  local observed = f.session:observe(keyboardContract.capability)
  f.owner, f.service = observed.context, observed.service
  local focus = f.session:observe(focusContract.capability)
  f.focus = focus.service
  f.target = focus.service:register(focus.context, {
    kind = 'local',
    wantsKeyboard = true,
    receiver = {
      key = function(event)
        f.keys[#f.keys + 1] = event.code
        return true
      end,
      text = function()
        return false
      end,
    },
  })
  f.target:focus()
  f.board = f.service:new(f.owner, options)
  local pointers = f.session:observe(interaction.capability)
  function f:pointer()
    return pointers.service:newPointer(pointers.context)
  end
  function f:update(pointer, buttons, x, y)
    pointer:update({
      origin = vector.pack((x or 0.025) - self.board.width / 2, self.board.height / 2 - (y or 0.025), 1),
      direction = vector.pack(0, 0, -1),
      pose = lovr.math.newMat4(),
      buttons = buttons or {},
      grip = false,
    }, { self.board })
  end
  function f:record()
    local onPointer = self.board.onPointer
    self.board.onPointer = function(board, event)
      self.events[#self.events + 1] = event
      if onPointer then
        onPointer(board, event)
      end
    end
  end
  function f:cancelled(pointer)
    local result = {}
    for _, event in self.events do
      if event.kind == 'cancel' and (not pointer or event.pointer == pointer) then
        result[#result + 1] = event
      end
    end
    return result
  end
  function f:draw()
    table.clear(self.drawn)
    self.board:draw(self.native.events.pass)
    return self.drawn
  end
  function f:close()
    self.session:close()
  end
  return f
end

for _, kind in { 'built-in', 'tiny' } do
  test(kind .. ' types once on primary press and ignores secondary buttons', function()
    local f = fixture(kind)
    local pointer = f:pointer()
    f:update(pointer, { right = true, middle = true, back = true, forward = true })
    expect.equal(#f.keys, 0, 'secondary presses never type')
    f:update(pointer)
    f:update(pointer, { left = true })
    expect.equal(#f.keys, 1, 'primary press keeps activation on the down edge')
    expect.equal(f.keys[1], keys.CODES.y)
    f:update(pointer, { left = true })
    f:update(pointer)
    expect.equal(#f.keys, 1, 'motion and release do not type again')
    if kind == 'built-in' then
      expect.equal(f.activations[1], pointer, 'the hook receives the actual pointer')
    end
    f:record()
    f:update(pointer, { left = true })
    expect.equal(#f.keys, 2, 'the protocol adapter still activates through its callback')
    expect.equal(f.focus:focused(), f.target, 'keyboard interaction does not steal local focus')
    f:close()
  end)

  test(kind .. ' tracking loss never types on cancellation or held reacquisition', function()
    local f = fixture(kind)
    local pointer = f:pointer()
    f:update(pointer, { left = true })
    pointer:withdraw()
    expect.equal(#f.keys, 1, 'tracking loss is not another activation')
    f:update(pointer, { left = true })
    expect.equal(#f.keys, 1, 'a held trigger cannot start another activation')
    f:update(pointer)
    f:update(pointer, { left = true })
    expect.equal(#f.keys, 2, 'an observed release permits a fresh primary press')
    f:close()
  end)

  for _, change in { 'hide', 'destroy' } do
    test(kind .. ' ' .. change .. ' cancels every pointer before visibility notification', function()
      local f
      local notifications = 0
      f = fixture(kind, {
        onVisibilityChanged = function(event)
          notifications += 1
          if notifications > 1 then
            return
          end
          expect.falsy(f.board.visible, 'visibility commits before callbacks')
          expect.equal(#f:cancelled(), 3, 'every captured button is cancelled before notification')
          expect.equal(event.reason, if change == 'hide' then 'hide' else 'destroy')
        end,
      })
      f:record()
      local first, second = f:pointer(), f:pointer()
      f:update(first, { left = true, right = true })
      f:update(second, { left = true })
      expect.equal(#f.keys, 2, 'two pointers activate independently')
      if change == 'hide' then
        f.board:setVisible(false)
      else
        f.board:destroy()
      end
      expect.equal(notifications, 1, 'one lifecycle notification')
      expect.equal(#f:cancelled(first), 2, 'both buttons of the first pointer cancel')
      expect.equal(#f:cancelled(second), 1, 'the second pointer cancels independently')
      for _, event in f:cancelled() do
        expect.equal(event.reason, if change == 'hide' then 'hidden' else 'control-removed')
      end
      if change == 'hide' then
        f.board:setVisible(true)
        f:update(first, { left = true, right = true })
        f:update(second, { left = true })
        expect.equal(#f.keys, 2, 'showing cannot restart held gestures')
        f:update(first)
        f:update(first, { left = true })
        expect.equal(#f.keys, 3, 'a fresh press after showing types')
      end
      f:close()
    end)
  end

  test(kind .. ' exposes unbounded projection while raycast stays bounded', function()
    local f = fixture(kind)
    expect.truthy(f.board.project, 'capture coordinates have a projection adapter')
    local origin = vector.pack(f.board.width, 0, 1)
    local x, y, distance = f.board:project(origin, vector.pack(0, 0, -1))
    expect.near(x, f.board.width * 1.5, 1e-6, 'projection does not clamp the coordinate')
    expect.near(y, f.board.height / 2, 1e-6)
    expect.near(distance, 1, 1e-6)
    expect.equal(f.board:raycast(origin, vector.pack(0, 0, -1)), nil, 'picking remains bounded')
    f:close()
  end)
end

for _, change in { 'layer', 'bounds' } do
  test('built-in ' .. change .. ' changes cancel captures before another control can activate', function()
    local f = fixture 'built-in'
    f:record()
    local pointer = f:pointer()
    f:update(pointer, { left = true })
    local selected = f.session:observe(theme.capability)
    local selection = selected.service:select(selected.context, { colors = { control = { 0.6, 0.5, 0.4, 1 } } })
    expect.equal(#f:cancelled(), 0, 'palette changes preserve this board capture')
    if change == 'layer' then
      f.board:setLayer 'alternate'
    else
      selection:update { metrics = { keyboardGap = 0.01 } }
      expect.near(f.board.width, 0.1, 1e-9, 'theme metrics never alter layout units')
    end
    expect.equal(#f:cancelled(), 1, 'an incompatible control change cancels immediately')
    expect.equal(f:cancelled()[1].reason, 'control-removed')
    f:update(pointer, { left = true })
    expect.equal(#f.keys, 1, 'a held gesture cannot activate a changed control')
    f:update(pointer)
    f:update(pointer, { left = true })
    expect.equal(#f.keys, 2, 'a fresh press activates the new control')
    f:close()
  end)
end

test('built-in hover leave and cancellation clear only the actual pointer', function()
  local f = fixture 'built-in'
  local first, second = f:pointer(), f:pointer()
  f:update(first, { left = true })
  f:update(second, { left = true }, 0.075)
  expect.truthy(f:draw()[keys.CODES.y], 'the first pointer hovers y')
  expect.truthy(f.drawn[keys.CODES.n], 'the second pointer hovers n')
  first:cancel(f.board, 'disabled')
  expect.falsy(f:draw()[keys.CODES.y], 'cancellation clears the first hover')
  expect.truthy(f.drawn[keys.CODES.n], 'cancellation preserves the second hover')
  f:update(second, { left = true }, f.board.width * 2)
  expect.falsy(f:draw()[keys.CODES.n], 'outside captured motion cannot leave stale hover')
  expect.equal(#f.keys, 2, 'neither cancellation nor outside movement types')
  f:close()
end)

for _, kind in { 'built-in', 'tiny' } do
  for _, change in { 'hide', 'destroy' } do
    test(kind .. ' ' .. change .. ' attempts every cancellation when callbacks raise', function()
      local f = fixture(kind)
      local first, second = f:pointer(), f:pointer()
      local onPointer = f.board.onPointer
      local cancelled = {}
      f.board.onPointer = function(board, event)
        onPointer(board, event)
        if event.kind == 'cancel' then
          cancelled[#cancelled + 1] = event.pointer
          expect.falsy(board.visible, 'visibility commits before cancellation')
          expect.equal(board.dead, change == 'destroy', 'death commits before destruction cancellation')
          expect.equal(#board:modifiers(), 0, 'modifiers clear before cancellation callbacks')
          error 'keyboard cancellation defect'
        end
      end
      f:update(first, { left = true, right = true })
      f:update(second, { left = true })
      f.board:pressKey(42)
      f.board:pressKey(58)
      expect.raises(function()
        if change == 'hide' then
          f.board:setVisible(false)
        else
          f.board:destroy()
        end
      end, 'keyboard cancellation defect')
      expect.equal(#cancelled, 3, 'every pointer and button cancellation runs')
      expect.equal(#f.keys, if kind == 'tiny' then 4 else 2, 'cancellation never types')
      if change == 'destroy' then
        expect.equal(#f.service:inspect().registrations, 0, 'board registration is released')
        for _, entry in f.focus:inspect().registrations do
          expect.truthy(entry.source ~= 'focus.newSource', 'source cleanup runs after cancellation failure')
        end
        expect.falsy(f.board:destroy(), 'failed callbacks cannot leave live gestures')
      else
        f.board:setVisible(false)
        expect.equal(#cancelled, 3, 'repeating hide never repeats cancelled callbacks')
      end
      f:close()
    end)
  end
end

for _, action in { { kind = 'hide' }, { kind = 'layer', layer = 'alternate' } } do
  test('built-in ' .. action.kind .. ' action cancels the capture that activates it', function()
    local f = fixture('built-in', { rows = { { { action = action } } } })
    f:record()
    local pointer = f:pointer()
    f:update(pointer, { left = true })
    expect.equal(#f:cancelled(), 1, 'capture bookkeeping precedes the key action')
    expect.equal(f:cancelled()[1].reason, if action.kind == 'hide' then 'hidden' else 'control-removed')
    expect.equal(#f.keys, 0, 'the action and its cancellation send no key')
    f:close()
  end)
end

for _, kind in { 'built-in', 'tiny' } do
  for _, closeAgain in { false, true } do
    local ending = if closeAgain then 'hides again' else 'reopens'
    test(kind .. ' cancellation ' .. ending .. ' without a stale outer hide notification', function()
      local f
      local notifications = {}
      local observedVisible = true
      f = fixture(kind, {
        onVisibilityChanged = function(change)
          notifications[#notifications + 1] = change
          observedVisible = change.visible
          expect.equal(change.visible, f.board.visible, 'notifications match the committed current visibility')
        end,
      })
      local first, second = f:pointer(), f:pointer()
      local cancelled, reentered, resets = 0, false, 0
      local reset = f.source.reset
      f.source.reset = function(source)
        resets += 1
        return reset(source)
      end
      local onPointer = f.board.onPointer
      f.board.onPointer = function(board, event)
        onPointer(board, event)
        if event.kind ~= 'cancel' then
          return
        end
        cancelled += 1
        if not reentered then
          reentered = true
          expect.falsy(board.visible, 'the outer hide commits before cancellation')
          board:setVisible(true)
          if closeAgain then
            board:setVisible(false)
          end
        end
        error('visibility reentry cancellation defect ' .. event.button)
      end
      f:update(first, { left = true, right = true })
      f:update(second, { left = true })
      local ok, failure = pcall(function()
        f.board:setVisible(false)
      end)
      expect.falsy(ok, 'cancellation errors still propagate after reentry')
      expect.truthy(tostring(failure):find('visibility reentry cancellation defect left', 1, true))
      expect.truthy(tostring(failure):find('visibility reentry cancellation defect right', 1, true))
      local reportedFailures = 0
      for _ in tostring(failure):gmatch 'visibility reentry cancellation defect' do
        reportedFailures += 1
      end
      expect.equal(reportedFailures, 3, 'every cancellation error remains in the aggregate')
      expect.equal(cancelled, 3, 'reentry never interrupts remaining pointer cancellation')
      expect.equal(#notifications, if closeAgain then 2 else 1, 'superseded outer hide does not notify')
      expect.equal(notifications[1].reason, 'show', 'the nested show remains observable')
      if closeAgain then
        expect.equal(notifications[2].reason, 'hide', 'only the current nested hide notifies')
      end
      expect.equal(f.board.visible, not closeAgain, 'the newest transition determines visibility')
      expect.equal(observedVisible, f.board.visible, 'consumer state matches the live board')
      expect.equal(resets, if closeAgain then 1 else 0, 'only the current hide resets input')
      f:close()
    end)
  end

  test(kind .. ' cancellation destruction ends notifications and never resets the dead source', function()
    local f
    local notifications = {}
    local weak = setmetatable({}, { __mode = 'v' })
    do
      local callback = function(change)
        notifications[#notifications + 1] = change
        expect.truthy(f.board.dead, 'destruction commits before its notification')
        expect.falsy(f.board.visible, 'a destroyed board cannot become visible')
        expect.equal(#f.service:inspect().registrations, 0, 'destruction removes the board registration')
        for _, entry in f.focus:inspect().registrations do
          expect.truthy(entry.source ~= 'focus.newSource', 'source teardown precedes destruction notification')
        end
      end
      weak.callback = callback
      f = fixture(kind, { onVisibilityChanged = callback })
    end
    local first, second = f:pointer(), f:pointer()
    local cancelled, reentered, resets = 0, false, 0
    local reset = f.source.reset
    f.source.reset = function(source)
      resets += 1
      if f.board.dead then
        error 'stale hide reset a dead keyboard source'
      end
      return reset(source)
    end
    local onPointer = f.board.onPointer
    f.board.onPointer = function(board, event)
      onPointer(board, event)
      if event.kind ~= 'cancel' then
        return
      end
      cancelled += 1
      if not reentered then
        reentered = true
        expect.falsy(board.visible, 'the outer hide commits before cancellation')
        expect.truthy(board:destroy(), 'cancellation can destroy the board')
      end
      error('destroy reentry cancellation defect ' .. event.button)
    end
    f:update(first, { left = true, right = true })
    f:update(second, { left = true })
    local ok, failure = pcall(function()
      f.board:setVisible(false)
    end)
    expect.falsy(ok, 'cancellation errors still reach the outer caller')
    expect.truthy(tostring(failure):find('destroy reentry cancellation defect left', 1, true))
    expect.truthy(tostring(failure):find('destroy reentry cancellation defect right', 1, true))
    local reportedFailures = 0
    for _ in tostring(failure):gmatch 'destroy reentry cancellation defect' do
      reportedFailures += 1
    end
    expect.equal(reportedFailures, 3, 'destruction never drops detached cancellation errors')
    expect.falsy(tostring(failure):find('stale hide reset a dead keyboard source', 1, true))
    expect.equal(cancelled, 3, 'every detached capture still cancels after destruction')
    expect.equal(resets, 0, 'outer hide never resets the destroyed source')
    expect.equal(#notifications, 1, 'destruction is the only terminal notification')
    expect.equal(notifications[1].reason, 'destroy')
    expect.truthy(f.board.dead)
    expect.falsy(f.board:destroy(), 'destruction remains idempotent after callback failures')
    f.board:setVisible(true)
    testing.collect()
    expect.equal(weak.callback, nil, 'a retained dead board releases its visibility callback')
    expect.equal(#testing.takeReports(), 0, 'propagated inverse failures are not reported twice')
    f:close()
    expect.equal(#notifications, 1, 'shutdown never emits a stale hide or a second destroy')
  end)
end

return test

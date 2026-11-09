local testing = require '@testing'
local plugin = require '@lunette-plugin'
local lunette = require '@lunette'
local focusContract = require '@lunette-contracts/focus'
local panelsContract = require '@lunette-contracts/panels'
local expect = testing.expect
local test = testing.suite()

local function fixture(): any
  local session = testing.boot { 'frame', 'focus' }
  require('@lunette').defaultSeat = function(): lunette.Seat?
    return nil
  end
  local observed = session:observe(focusContract.capability)
  local f = { session = session, focus = observed.service, owner = observed.context, events = {}, panels = {} }
  local listeners, added = {}, {}
  local service = {
    onAdded = function(_self: any, owner: testing.Context, listener: panelsContract.AddedListener): plugin.Effect
      return owner:effect(function(): () -> ()
        added[listener] = true
        return function()
          added[listener] = nil
        end
      end)
    end,
    isInputLocked = function(_self: any, sink: lunette.Sink): boolean
      for _, panel in f.panels do
        if panel.sink == sink and panel.locked then
          return true
        end
      end
      return false
    end,
    onLockChanged = function(_self: any, owner: testing.Context, listener: panelsContract.AddedListener): plugin.Effect
      return owner:effect(function(): () -> ()
        listeners[listener] = true
        return function()
          listeners[listener] = nil
        end
      end)
    end,
  }
  function f:connect()
    self.provider = session:use(plugin.provider({
      name = 'testing/focus-panels',
      capability = panelsContract.capability,
      build = function(): any
        return service
      end,
    }).definition)
  end
  function f:panel(id: number, domain: ('window' | 'host')?): any
    local sink = { dead = false, domain = domain or 'window', id = id }
    function sink:setModifiers(modifiers: { lunette.ModifierName }?): boolean
      table.insert(f.events, 'mods:' .. table.concat(modifiers or {}, '+'))
      if f.modifiers then
        f.modifiers()
      end
      return true
    end
    function sink:key(code: number, pressed: boolean): boolean
      table.insert(f.events, tostring(code) .. ':' .. tostring(pressed))
      if pressed and f.pressed then
        f.pressed()
      elseif not pressed and f.released then
        f.released()
      end
      return true
    end
    function sink:typeText(value: string): boolean
      table.insert(f.events, 'text:' .. value)
      return true
    end
    local panel = { sink = sink, source = { sink = sink }, locked = false }
    table.insert(self.panels, panel)
    return panel
  end
  function f:seat(id: number): any
    local seat = { id = id, dead = false }
    function seat:setFocus(sink: lunette.Sink?): boolean
      self.focus = sink
      table.insert(f.events, 'seat:' .. id .. ':' .. (if sink then tostring(sink.id) else 'clear'))
      if sink and f.established then
        f.established()
      elseif not sink and f.cleared then
        f.cleared()
      end
      return true
    end
    return seat
  end
  function f:target(panel: any, seat: lunette.Seat?, sink: lunette.Sink?): focusContract.TargetHandle
    return self.focus:register(self.owner, { kind = 'native', sink = sink or panel.sink, seat = seat })
  end
  function f:announce(panel: any)
    for listener in pairs(table.clone(added)) do
      if added[listener] then
        listener.run(panel)
      end
    end
  end
  function f:lock(panel: any, locked: boolean, silent: boolean?)
    panel.locked = locked
    if not silent then
      if f.beforeLock then
        f.beforeLock(panel)
      end
      for listener in pairs(table.clone(listeners)) do
        if listeners[listener] then
          listener.run(panel)
        end
      end
    end
  end
  f:connect()
  return f
end

test('locked native registrations refuse focus without displacing a local route', function()
  local f = fixture()
  local panel, seat = f:panel(1), f:seat(11)
  local target = f:target(panel, seat)
  local field = f.focus:register(f.owner, {
    kind = 'local',
    wantsKeyboard = true,
    receiver = {
      key = function(): boolean
        return true
      end,
      text = function(): boolean
        return true
      end,
    },
  })
  field:focus()
  f:lock(panel, true)
  expect.falsy(target:focus(), 'a directly registered locked sink refuses focus')
  expect.equal(f.focus:focused(), field, 'local focus is unaffected')
  expect.equal(seat.focus, nil, 'no native authority is acquired')
  f.session:close()
end)

test('lock changes clear every matching seat including noncurrent registrations', function()
  local f = fixture()
  local panel, other = f:panel(1), f:panel(2)
  local left, right, third = f:seat(11), f:seat(12), f:seat(13)
  f:target(panel, left):focus()
  f:target(panel, right):focus()
  local current = f:target(other, third)
  current:focus()
  f:lock(panel, true)
  expect.equal(left.focus, nil, 'the oldest authority clears')
  expect.equal(right.focus, nil, 'the second authority clears')
  expect.equal(third.focus, other.sink, 'unrelated native authority stays')
  expect.equal(f.focus:focused(), current, 'an unrelated route stays current')
  f.session:close()
end)

test('locking the current route revokes it and unlock restores nothing', function()
  local f = fixture()
  local panel, seat = f:panel(1), f:seat(11)
  local target = f:target(panel, seat)
  target:focus()
  f:lock(panel, true)
  expect.equal(f.focus:focused(), nil, 'the current route is revoked immediately')
  expect.equal(seat.focus, nil, 'native focus clears immediately')
  f:lock(panel, false)
  expect.equal(f.focus:focused(), nil, 'unlock does not restore focus')
  expect.truthy(target:focus(), 'explicit focus after unlock succeeds')
  f.session:close()
end)

test('refocusing a current handle checks authoritative lock state without an event', function()
  local f = fixture()
  local panel, seat = f:panel(1), f:seat(11)
  local target = f:target(panel, seat)
  target:focus()
  f:lock(panel, true, true)
  expect.falsy(target:focus(), 'the current handle cannot bypass a lock')
  expect.equal(seat.focus, nil, 'stale authority is revoked')
  f.session:close()
end)

test('snapshot delivery and batch processing sweep authoritative locks without an event', function()
  local f = fixture()
  local panel, seat = f:panel(1), f:seat(11)
  local target = f:target(panel, seat)
  local input = f.focus:newSource(f.owner, { mode = 'physical' })
  target:focus()
  input:beginBatch(1)
  f:lock(panel, true, true)
  expect.equal(input:text('blocked', 1).kind, 'refused', 'a batch cannot deliver to a newly locked sink')
  expect.equal(seat.focus, nil, 'snapshot clears native authority')
  f:lock(panel, false)
  target:focus()
  f:lock(panel, true, true)
  f.session:update()
  expect.equal(seat.focus, nil, 'frame sweep also clears native authority')
  f.session:close()
end)

test('locking during key down releases keys and modifiers before clearing seat authority', function()
  local f = fixture()
  local panel, seat = f:panel(1), f:seat(11)
  f:target(panel, seat):focus()
  local input = f.focus:newSource(f.owner)
  table.clear(f.events)
  f.pressed = function()
    f:lock(panel, true)
  end
  expect.equal(input:key({ code = 30, modifiers = { 'shift' } }).kind, 'refused', 'the operation is invalidated')
  expect.equal(
    table.concat(f.events, ','),
    'mods:shift,30:true,30:false,mods:,seat:11:clear',
    'inverses precede revocation'
  )
  f.session:close()
end)

test('locking while native focus is being established cannot leave untracked authority', function()
  local f = fixture()
  local panel, seat = f:panel(1), f:seat(11)
  local target = f:target(panel, seat)
  f.established = function()
    f:lock(panel, true)
  end
  expect.falsy(target:focus(), 'the in-flight transition refuses the locked sink')
  expect.equal(seat.focus, nil, 'the in-flight native authority is cleared')
  expect.equal(f.focus:focused(), nil, 'no locked route is committed')
  f.session:close()
end)

test('lock cleanup tolerates reentrant lock notifications during native inverses', function()
  local f = fixture()
  local panel, seat = f:panel(1), f:seat(11)
  local target = f:target(panel, seat)
  target:focus()
  local input = f.focus:newSource(f.owner)
  f.pressed = function()
    f:lock(panel, true)
  end
  f.modifiers = function()
    if panel.locked then
      f:lock(panel, true)
      expect.falsy(target:focus(), 'cleanup cannot reacquire the locked route')
    end
  end
  expect.equal(input:key({ code = 30 }).kind, 'refused', 'reentrant cleanup invalidates delivery')
  expect.equal(seat.focus, nil, 'authority clears once cleanup completes')
  expect.equal(#f.session.native.events.reported, 0, 'no recursive cleanup error')
  f.session:close()
end)

test('sink equality associates equivalent delivery handles rather than table keys', function()
  local f = fixture()
  local panel, seat = f:panel(1), f:seat(11)
  local identity = {
    __eq = function(a: any, b: any): boolean
      return a.id == b.id
    end,
  }
  setmetatable(panel.sink, identity)
  local equivalent = setmetatable(table.clone(panel.sink), identity)
  expect.truthy(equivalent == panel.sink, 'the handles share delivery identity')
  local target = f:target(panel, seat, equivalent)
  target:focus()
  f:lock(panel, true)
  expect.equal(seat.focus, nil, 'equivalent sink authority clears')
  expect.falsy(target:focus(), 'equivalent handles cannot bypass the lock')
  f.session:close()
end)

test('locking a host monitor preserves the distinct current host monitor route', function()
  local f = fixture()
  local first, second = f:panel(1, 'host'), f:panel(2, 'host')
  f:target(first):focus()
  local current = f:target(second)
  current:focus()
  f:lock(first, true)
  expect.equal(f.focus:focused(), current, 'shared host keyboard is not shared monitor identity')
  f:lock(second, true)
  expect.equal(f.focus:focused(), nil, 'the matching monitor route clears')
  f.session:close()
end)

test('panels detach revokes native routes before disconnecting and does not restore on reconnect', function()
  local f = fixture()
  local first, second = f:panel(1), f:panel(2)
  local left, right = f:seat(11), f:seat(12)
  f:target(first, left):focus()
  local current = f:target(second, right)
  current:focus()
  f.cleared = function()
    expect.falsy(current:focus(), 'reentrant focus during detach fails closed')
  end
  f.provider:disable()
  expect.equal(left.focus, nil, 'prior authority clears on detach')
  expect.equal(right.focus, nil, 'current authority clears on detach')
  expect.equal(f.focus:focused(), nil, 'no route survives detach')
  f.cleared = nil
  f.provider:enable()
  expect.equal(f.focus:focused(), nil, 'reconnect restores nothing')
  f.session:close()
end)

test('a newly added locked panel immediately revokes focus acquired through its raw sink', function()
  local f = fixture()
  local panel, seat = f:panel(1), f:seat(11)
  local target = f:target(panel, seat)
  target:focus()
  f:lock(panel, true, true)
  f:announce(panel)
  expect.equal(seat.focus, nil, 'panel arrival clears existing raw sink authority')
  expect.equal(f.focus:focused(), nil, 'panel arrival clears the route immediately')
  f.session:close()
end)

test('focus observers can query and register matching targets during lock revocation', function()
  local f = fixture()
  local panel, seat = f:panel(1), f:seat(11)
  local target = f:target(panel, seat)
  target:focus()
  local changes = 0
  f.focus:onChanged(f.owner, {
    run = function(change: focusContract.Change)
      changes += 1
      expect.equal(change.kind, 'none', 'the observer sees revocation')
      expect.equal(f.focus:focused(), nil, 'a nested eligibility sweep stays empty')
      expect.falsy(target:focus(), 'the previous handle refuses focus')
      expect.falsy(f:target(panel, seat):focus(), 'a newly registered matching handle also refuses focus')
    end,
  })
  f:lock(panel, true)
  expect.equal(changes, 1, 'revocation notifies once despite nested queries')
  expect.equal(#f.session.native.events.reported, 0, 'nested observation reports no errors')
  f.session:close()
end)

test('an earlier lock listener unlocking the panel cannot preserve its native authorities', function()
  local f = fixture()
  local panel, seat = f:panel(1), f:seat(11)
  f:target(panel, seat):focus()
  f.beforeLock = function(changed: any)
    changed.locked = false
  end
  f:lock(panel, true)
  expect.falsy(panel.locked, 'the earlier listener unlocks the panel')
  expect.equal(seat.focus, nil, 'the original transition still revokes native authority')
  expect.equal(f.focus:focused(), nil, 'no route is restored')
  f.session:close()
end)

test('unlock during key release cannot reacquire authority or restore the revoked route', function()
  local f = fixture()
  local panel, seat = f:panel(1), f:seat(11)
  local target = f:target(panel, seat)
  target:focus()
  local input = f.focus:newSource(f.owner)
  f.pressed = function()
    f:lock(panel, true)
  end
  f.modifiers = function()
    if panel.locked then
      f:lock(panel, false)
      expect.falsy(target:focus(), 'unlock cannot reenter an active inverse')
    end
  end
  expect.equal(input:key({ code = 30 }).kind, 'refused', 'the stroke remains invalidated')
  expect.equal(seat.focus, nil, 'native authority stays withdrawn')
  expect.equal(f.focus:focused(), nil, 'unlock during an inverse does not restore focus')
  expect.equal(#f.session.native.events.reported, 0, 'nested unlock reports no errors')
  f.session:close()
end)

test('lock during ordinary key release defers revocation without poisoning successful cleanup', function()
  local f = fixture()
  local panel, seat = f:panel(1), f:seat(11)
  local target = f:target(panel, seat)
  target:focus()
  local input = f.focus:newSource(f.owner)
  f.released = function()
    f:lock(panel, true)
    f:lock(panel, false)
    expect.falsy(f:target(panel, seat):focus(), 'a fresh handle cannot reenter ordinary cleanup')
  end
  expect.equal(input:key({ code = 30 }).kind, 'refused', 'release-time lock invalidates delivery')
  expect.equal(seat.focus, nil, 'cleanup completes before native withdrawal')
  f.released = nil
  expect.truthy(target:focus(), 'successful inverse cleanup does not poison later explicit focus')
  f.session:close()
end)

test('refused in-flight native focus cannot restore a prior route revoked during the call', function()
  local f = fixture()
  local panel, other, seat = f:panel(1), f:panel(2), f:seat(11)
  f:target(panel, seat):focus()
  local original = seat.setFocus
  seat.setFocus = function(self: any, sink: lunette.Sink?): boolean
    if sink == other.sink then
      f:lock(panel, true)
      return false
    end
    return original(self, sink)
  end
  expect.falsy(f:target(other, seat):focus(), 'the new focus is refused')
  expect.equal(seat.focus, nil, 'the masked previous authority is still withdrawn')
  f.session:close()
end)

return test

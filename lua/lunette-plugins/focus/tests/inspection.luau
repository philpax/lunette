local testing = require '@testing'
local expect = testing.expect
local contract = require '@lunette-contracts/focus'
local test = testing.suite()

local function count(snapshot, kind)
  local total = 0
  for _, entry in ipairs(snapshot.registrations) do
    if entry.kind == kind then
      total += 1
    end
  end
  return total
end

test('inspection lists route registrations and sources without native getters or callbacks', function()
  testing.native()
  local session = testing.start { 'focus' }
  local observed = session:observe(contract.capability)
  local service, owner = observed.service, observed.context
  local setFocusCalls = 0
  local seat = {
    id = 24,
    dead = false,
    setFocus = function()
      setFocusCalls += 1
      return true
    end,
  }
  local sink = { dead = false, domain = 'window', id = 1 }
  local target = service:register(owner, { kind = 'native', seat = seat, sink = sink })
  target:focus()
  local changed = service:onChanged(owner, {
    run = function()
      error 'inspection delivered focus'
    end,
  })
  local input = service:newSource(owner, { mode = 'virtual' })
  local before = setFocusCalls
  local snapshot = service:inspect()
  expect.equal(setFocusCalls, before, 'inspection makes no native focus calls')
  expect.equal(#snapshot.registrations, 3, 'one target, listener, and source')
  expect.equal(count(snapshot, 'focus'), 1, 'one logical route registration')
  expect.equal(snapshot.state.sourceCount, 1, 'one source')
  for _, entry in ipairs(snapshot.registrations) do
    expect.equal(entry.owner, owner, 'the registration owner')
    expect.falsy(entry.details.receiver, 'receiver closures are private')
  end
  changed:dispose()
  input:destroy()
  target:destroy()
  expect.equal(#service:inspect().registrations, 0, 'all released registrations disappear')
  session:close()
end)

return test

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

test('inspection retains one grant per owner and seat without changing native focus', function()
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
    end,
  }
  local sink = { dead = false }
  local grant = service:setFocus(owner, { seat = seat, sink = sink })
  expect.equal(service:setFocus(owner, { seat = seat, sink = sink }), grant, 'the reused grant')
  local changed = service:onChanged(owner, {
    run = function()
      error 'inspection delivered focus'
    end,
  })
  local callsBeforeInspect = setFocusCalls
  local snapshot = service:inspect()
  expect.equal(setFocusCalls, callsBeforeInspect, 'inspection makes no native focus calls')
  expect.equal(snapshot.logicalRegistrationCount, 2, 'one grant and one listener')
  expect.equal(count(snapshot, 'focus'), 1, 'one logical focus grant')
  for _, entry in ipairs(snapshot.registrations) do
    expect.equal(entry.owner, owner, 'the actual owner')
  end
  changed:dispose()
  grant:dispose()
  expect.equal(service:inspect().logicalRegistrationCount, 0, 'the released grants')
  session:close()
end)

return test

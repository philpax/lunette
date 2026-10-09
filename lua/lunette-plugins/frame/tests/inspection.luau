local testing = require '@testing'
local expect = testing.expect
local contract = require '@lunette-contracts/frame'
local test = testing.suite()

test('inspection describes every frame registration without dispatch', function()
  local session = testing.start { 'frame' }
  local observed = session:observe(contract.capability)
  local service, owner = observed.service, observed.context
  local function never()
    error 'inspection dispatched a handler'
  end
  local effects = {
    service:onUpdate(owner, { phase = 'scene', order = 12, run = never }),
    service:onDraw(owner, { phase = 'overlay', run = never }),
    service:onKey(owner, { run = never }),
    service:onText(owner, { phase = 'delivery', run = never }),
    service:onQuit(owner, { run = never }),
    service:onBatch(owner, { run = never }),
  }
  local snapshot = service:inspect()
  expect.equal(#snapshot.registrations, 6, 'all handler kinds')
  expect.equal(snapshot.registrations[1].source, 'frame.onBatch', 'the batch observer source')
  expect.equal(snapshot.registrations[1].details.phase, 'batch', 'the batch observer phase')
  expect.equal(snapshot.registrations[2].details.phase, 'scene', 'the update phase')
  expect.equal(snapshot.registrations[2].details.order, 12, 'the update order')
  for _, entry in ipairs(snapshot.registrations) do
    expect.equal(entry.owner, owner, 'the handler owner')
  end
  for _, effect in ipairs(effects) do
    effect:dispose()
  end
  expect.equal(#service:inspect().registrations, 0, 'disposed handlers')
  session:close()
end)

return test

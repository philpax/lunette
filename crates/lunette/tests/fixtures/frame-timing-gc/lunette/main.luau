-- Checks collection reports at the public observer boundary of actual boot frames.
local native = require '@lunette'
local expectedBudget = assert(tonumber(arg[1]))
local count = 0
local steps = 0
local frames = 0
local cancel: () -> ()

native.onError(function()
  lovr.event.quit(21)
end)

cancel = native.observeFrameTiming(function(record: native.FrameTiming)
  assert(record.gcBudgetUs == expectedBudget)
  assert(record.gc ~= nil and record.gc >= 0)
  assert(record.gcSteps ~= nil and record.gcSteps >= 0)
  assert(record.gcCycleCompleted ~= nil and record.gcOverrun ~= nil)
  steps += assert(record.gcSteps)
  if expectedBudget == 0 then
    assert(record.gcSteps == 0 and record.gc == 0)
    assert(record.gcCycleCompleted == false and record.gcOverrun == false)
  end
  count += 1
  if count == 8 then
    assert(expectedBudget == 0 or steps > 0)
    cancel()
    lovr.event.quit(19)
  end
end)

if arg[2] == 'cancel' then
  cancel()
end

function lovr.update()
  frames += 1
  if frames == 16 then
    lovr.event.quit(22)
  end
  local garbage = {}
  for index = 1, 100 do
    garbage[index] = { index }
  end
end

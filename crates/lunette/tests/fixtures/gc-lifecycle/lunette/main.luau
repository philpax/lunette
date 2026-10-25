-- A suspended coroutine survives proactive work, restart replaces the state, and errors reach the error handler.

local frames = 0
local retained = { answer = 42 }
local worker = coroutine.create(function(): number
  coroutine.yield(retained)
  return retained.answer
end)

assert(coroutine.resume(worker))

function lovr.restart(): number
  return 42
end

function lovr.errhand(message: unknown): () -> number
  assert(tostring(message):find('gc lifecycle fixture: expected error', 1, true))
  return function(): number
    return 17
  end
end

function lovr.update()
  frames += 1
  local garbage = {}
  for index = 1, 100 do
    garbage[index] = { index }
  end
  if frames < 3 then
    return
  end
  local ok, answer = coroutine.resume(worker)
  assert(ok and answer == 42)
  if arg.restart == nil then
    lovr.event.restart()
  else
    assert(arg.restart == 42)
    error 'gc lifecycle fixture: expected error'
  end
end

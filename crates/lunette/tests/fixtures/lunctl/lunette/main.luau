-- A session that runs until lunctl sets the `stop` global.
--
-- `lunctl` evaluates chunks in the main state, where they reach globals, not locals.
-- A chunk reaches `lunette` through the evaluator's module lookup, so the
-- fixture does not require it.

answer = 42
title = 'a terminal'
nested = { count = 2, names = { 'a', 'b' } }

-- A bound on the run: a test whose lunctl never connects quits with its own
-- status before the harness times out.
local LIMIT = 60
local started = lovr.timer.getTime()

function lovr.update()
  if stop then
    lovr.event.quit(9)
  elseif lovr.timer.getTime() - started > LIMIT then
    print('lunette: nothing reached the control socket within ' .. LIMIT .. ' seconds')
    lovr.event.quit(11)
  end
end

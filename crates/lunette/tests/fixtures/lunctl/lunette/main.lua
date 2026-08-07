-- A session that runs until lunctl tells it to stop.
--
-- Everything a chunk reads is a global, because that is what a chunk can reach:
-- `lunctl` evaluates in the main state, and a local in this file is not in it.

-- A global, not a local: a chunk is evaluated in the main state and cannot
-- see this file's locals, so anything a chunk should reach is reached this way.
lunette = require 'lunette'

answer = 42
title = 'a terminal'
nested = { count = 2, names = { 'a', 'b' } }

-- A bound on the run, so a test whose lunctl never connects ends with a status
-- of its own rather than hanging until the harness gives up.
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

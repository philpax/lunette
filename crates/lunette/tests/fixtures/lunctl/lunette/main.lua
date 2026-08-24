-- A session that runs until lunctl tells it to stop. Values read by a chunk must
-- be globals because lunctl evaluates chunks in the main Lua state.

lunette = require '@lunette'

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

-- A configuration that does not compile.
--
-- Deliberately, and this is the whole fixture: `lunette-v1.AC8.4` is about what
-- happens when a user leaves a `main.lua` in this state, and the only way to
-- establish it is to leave one in this state.
--
-- Callbacks are defined before the defect so that the case can assert they are
-- not left bound: a `main.lua` that raises partway through has already installed
-- some of itself.

function lovr.update()
  running = true
end

local this is not lua

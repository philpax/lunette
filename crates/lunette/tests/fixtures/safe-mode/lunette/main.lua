-- A configuration that does not compile.
--
-- The compile failure is the fixture: it establishes the case of a user
-- leaving a `main.lua` in this state, which no other fixture can establish
-- except by leaving one in this state.
--
-- Callbacks are defined before the defect so the case can assert they are not
-- left bound: a `main.lua` that raises partway through has already installed
-- some of itself.

function lovr.update()
  running = true
end

local this is not lua

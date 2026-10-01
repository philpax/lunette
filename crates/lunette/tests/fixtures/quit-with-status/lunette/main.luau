-- Quits with a status the host must report verbatim.
--
-- The value is neither 0 nor 1, so a host reading the wrong Lua stack slot
-- cannot produce it by accident.

function lovr.load()
  lovr.event.quit(3)
end

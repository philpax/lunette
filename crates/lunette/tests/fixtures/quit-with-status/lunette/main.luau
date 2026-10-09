-- Quits with a status the host must report verbatim. It is neither 0 nor 1, so
-- a host reading the wrong stack slot cannot produce it by accident.

function lovr.load()
  lovr.event.quit(3)
end

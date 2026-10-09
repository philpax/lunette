-- Quits without naming a status, which boot.lua turns into 0.
-- This keeps the sibling fixture from passing because every exit reports the same number.

function lovr.load()
  lovr.event.quit()
end

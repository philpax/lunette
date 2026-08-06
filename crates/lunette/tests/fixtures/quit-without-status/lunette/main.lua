-- Quits without naming a status.
--
-- boot.lua substitutes 0 (vendor/lovr/etc/boot.lua:197), so this is the case
-- that pins ordinary success down and keeps the sibling fixture from passing
-- for the trivial reason that every exit reports the same number.

function lovr.load()
  lovr.event.quit()
end

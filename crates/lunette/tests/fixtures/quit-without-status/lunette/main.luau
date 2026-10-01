-- Quits without naming a status.
--
-- boot.lua substitutes 0 (vendor/lovr/etc/boot.lua). This fixture fixes
-- the ordinary success exit. The sibling fixture cannot pass for the trivial
-- reason that every exit reports the same number.

function lovr.load()
  lovr.event.quit()
end

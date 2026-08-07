-- Configuration for the soft-reload fixture.
--
-- The session has to reach `lovr.load` on a machine with no display, no XR
-- runtime, and no sound device, so everything that would want one is switched
-- off. `lovr.math` stays on, because the mullion modules this fixture requires
-- build `Mat4`s as they place panels.

function lovr.conf(t)
  -- Distinct from the other fixtures' identities: boot.lua creates
  -- $XDG_DATA_HOME/LOVR/<identity> on every run, and two runs sharing a leaf
  -- race to create it.
  t.identity = 'lunette-reload'

  -- As the shipped configuration does: the LÖVR default mounts the save
  -- directory ahead of everything else, so a write to a standard-library path
  -- would shadow the module rather than being kept apart from it.
  t.saveprecedence = false

  t.window = nil
  t.modules.audio = false
  t.modules.graphics = false
  t.modules.headset = false
end

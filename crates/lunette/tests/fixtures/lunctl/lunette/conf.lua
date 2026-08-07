-- Configuration for the lunctl fixture.
--
-- The session has to keep running on a machine with no display, no XR runtime,
-- and no sound device, so everything that would want one is switched off.

function lovr.conf(t)
  -- Distinct from the other fixtures' identities: boot.lua creates
  -- $XDG_DATA_HOME/LOVR/<identity> on every run, and two runs sharing a leaf
  -- race to create it.
  t.identity = 'lunette-lunctl'

  t.saveprecedence = false

  t.window = nil
  t.modules.audio = false
  t.modules.graphics = false
  t.modules.headset = false
end

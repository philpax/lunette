-- Configuration for the safe-mode fixture.
--
-- `conf.lua` loads and `main.lua` does not, which is the case safe mode is for:
-- everything native comes up, and then the configuration on top of it will not.
-- The session has to keep running on a machine with no display, no XR runtime,
-- and no sound device, so everything that would want one is switched off.

function lovr.conf(t)
  -- Distinct from the other fixtures' identities: boot.lua creates
  -- $XDG_DATA_HOME/LOVR/<identity> on every run, and two runs sharing a leaf
  -- race to create it.
  t.identity = 'lunette-safe-mode'

  t.saveprecedence = false

  t.window = nil
  t.modules.audio = false
  t.modules.graphics = false
  t.modules.headset = false
end

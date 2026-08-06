-- Configuration for the non-zero exit-status fixture.
--
-- The session has to reach `lovr.load` on a machine with no display, no XR
-- runtime, and no sound device, so everything that would want one is switched
-- off. Setting t.window = nil is what suppresses the window; boot.lua opens one
-- whenever conf.window is set (vendor/lovr/etc/boot.lua:171). The three modules
-- are disabled so that the run reports the same status on a developer's desktop
-- as it does on a headless machine.

function lovr.conf(t)
  -- Distinct from the other fixture's identity: boot.lua creates
  -- $XDG_DATA_HOME/LOVR/<identity> on every run, and two runs sharing a leaf
  -- race to create it.
  t.identity = 'lunette-quit-with-status'

  t.window = nil
  t.modules.audio = false
  t.modules.graphics = false
  t.modules.headset = false
end

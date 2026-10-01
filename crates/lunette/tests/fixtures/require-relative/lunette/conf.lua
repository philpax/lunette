-- Configuration for the relative-require fixture.
--
-- The session has to reach `lovr.load` on a machine with no display, no XR
-- runtime, and no sound device, so the modules that depend on those are off.
-- Setting t.window = nil suppresses the window; boot.lua opens one whenever
-- conf.window is set (vendor/lovr/etc/boot.lua). The three modules are
-- disabled so the run reports the same status on a developer's desktop and
-- on a headless machine.

function lovr.conf(t)
  -- This identity is distinct from the other fixtures' identities. boot.lua
  -- creates $XDG_DATA_HOME/LOVR/<identity> on every run, and two runs sharing
  -- a leaf race to create it.
  t.identity = 'lunette-require-relative'

  t.window = nil
  t.modules.audio = false
  t.modules.graphics = false
  t.modules.headset = false
end

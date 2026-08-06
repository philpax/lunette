-- Configuration for the zero exit-status fixture.
--
-- The session has to reach `lovr.load` on a machine with no display, no XR
-- runtime, and no sound device, so everything that would want one is switched
-- off. Setting t.window = nil is what suppresses the window; boot.lua opens one
-- whenever conf.window is set (vendor/lovr/etc/boot.lua:171). The three modules
-- are disabled so that the run reports the same status on a developer's desktop
-- as it does on a headless machine.

function lovr.conf(t)
  t.identity = 'lunette-exit-status'

  t.window = nil
  t.modules.audio = false
  t.modules.graphics = false
  t.modules.headset = false
end

-- Configuration for the module root mount fixture.
--
-- The modules that need a display, an XR runtime, or a sound device are off,
-- and `t.window = nil` suppresses the window.

function lovr.conf(t: LovrConfiguration)
  -- A distinct identity, because boot.lua creates
  -- $XDG_DATA_HOME/LOVR/<identity> on every run and two runs sharing a leaf
  -- race to create it.
  t.identity = 'lunette-require-root'

  -- The save directory mounts ahead of everything else, so a write to a module
  -- root's path would shadow the module.
  t.saveprecedence = false

  t.window = nil
  t.modules.audio = false
  t.modules.graphics = false
  t.modules.headset = false
end

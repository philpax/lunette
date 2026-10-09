-- Configuration for the fixture with no main.luau, the case safe mode is for.
-- The modules that need a display, an XR runtime, or a sound device are off so the session runs headless.

function lovr.conf(t)
  -- A distinct identity, because boot.lua creates $XDG_DATA_HOME/LOVR/<identity> and two runs sharing a leaf race to create it.
  t.identity = 'lunette-safe-mode-no-main'

  t.saveprecedence = false

  t.window = nil
  t.modules.audio = false
  t.modules.graphics = false
  t.modules.headset = false
end

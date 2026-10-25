-- Configuration for the tiered-execution fixture.
-- The modules that need a display, an XR runtime, or a sound device are off so the run behaves the same headless.

function lovr.conf(t: LovrConfiguration)
  -- A distinct identity, because boot.lua creates $XDG_DATA_HOME/LOVR/<identity> and two runs sharing a leaf race to create it.
  t.identity = 'lunette-tiered'

  t.window = nil
  t.modules.audio = false
  t.modules.graphics = false
  t.modules.headset = false
end

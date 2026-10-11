-- Configuration for the relative-require fixture. The window and hardware
-- modules are off so the run behaves the same on a headless machine.

function lovr.conf(t: LovrConfiguration)
  -- A distinct identity, because two runs sharing a save directory race to create it.
  t.identity = 'lunette-require-relative'

  t.window = nil
  t.modules.audio = false
  t.modules.graphics = false
  t.modules.headset = false
end

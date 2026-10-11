-- Configuration for the zero exit-status fixture.
--
-- The window and the hardware modules are off so the run behaves the same on a
-- desktop and on a headless machine.

function lovr.conf(t: LovrConfiguration)
  -- Distinct per fixture, because two runs sharing a save directory race to
  -- create it.
  t.identity = 'lunette-quit-without-status'

  t.window = nil
  t.modules.audio = false
  t.modules.graphics = false
  t.modules.headset = false
end

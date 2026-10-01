-- Configuration for the relative-require fixture. The window, audio, graphics, and headset are off so the
-- run behaves the same on a headless machine.

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

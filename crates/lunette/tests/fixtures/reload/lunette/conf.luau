-- Configuration for the soft-reload fixture.
--
-- The hardware modules are off so the run needs no display, XR runtime, or
-- sound device. `lovr.math` stays on, because the required vocabulary decodes
-- poses into `Mat4`s.

function lovr.conf(t)
  -- A distinct identity, because two runs sharing a save directory race to create it.
  t.identity = 'lunette-reload'

  -- By default LÖVR mounts the save directory first, so a write would shadow
  -- a standard-library module.
  t.saveprecedence = false

  t.window = nil
  t.modules.audio = false
  t.modules.graphics = false
  t.modules.headset = false
end

-- Configuration for the mullion spec run.
--
-- The session has to reach `lovr.load` on a machine with no display, no XR
-- runtime, and no sound device, so the modules that depend on those are off.
-- `lovr.math` stays on: the panel specs raycast against real `Mat4`s, and a
-- reimplementation in the spec would assert the spec's own arithmetic.

function lovr.conf(t)
  -- This identity is distinct from the other fixtures' identities. boot.lua
  -- creates $XDG_DATA_HOME/LOVR/<identity> on every run, and two runs sharing
  -- a leaf race to create it.
  t.identity = 'lunette-mullion-spec'

  -- The shipped configuration does the same, for the reason recorded there: the
  -- LÖVR default mounts the save directory ahead of everything else, so a write
  -- to a standard-library path would shadow the module. The write stays apart
  -- from the module instead.
  t.saveprecedence = false

  t.window = nil
  t.modules.audio = false
  t.modules.graphics = false
  t.modules.headset = false
end

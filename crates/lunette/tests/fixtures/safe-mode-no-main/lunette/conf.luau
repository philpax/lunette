-- Configuration for the fixture with no main.luau.
--
-- `conf.luau` loads and `main.luau` does not, which is the case safe mode is
-- for: everything native loads, and then the configuration above it does
-- not. The session has to keep running on a machine with no display, no XR
-- runtime, and no sound device, so the modules that depend on those are off.

function lovr.conf(t)
  -- This identity is distinct from the other fixtures' identities. boot.lua
  -- creates $XDG_DATA_HOME/LOVR/<identity> on every run, and two runs sharing
  -- a leaf race to create it.
  t.identity = 'lunette-safe-mode-no-main'

  t.saveprecedence = false

  t.window = nil
  t.modules.audio = false
  t.modules.graphics = false
  t.modules.headset = false
end

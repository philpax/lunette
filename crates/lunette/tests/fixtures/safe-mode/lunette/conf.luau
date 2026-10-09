-- Configuration for the safe-mode fixture.
--
-- `conf.luau` loads and `main.luau` does not, which is the case safe mode is
-- for. The hardware modules are off so the session runs headless.

function lovr.conf(t)
  -- Distinct per fixture, because two runs sharing a save directory race to
  -- create it.
  t.identity = 'lunette-safe-mode'

  t.saveprecedence = false

  t.window = nil
  t.modules.audio = false
  t.modules.graphics = false
  t.modules.headset = false
end

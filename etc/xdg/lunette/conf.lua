-- The default lunette configuration.
--
-- lunette loads this directory when the user has none of their own. Run
-- `lunette --dump-config` to put a copy in $XDG_CONFIG_HOME/lunette and edit it
-- there. The command writes a `.luaurc` naming this installation's standard
-- library. The `.luaurc` makes `lunette check` and an editor resolve `@mullion`
-- and `@lunette` from wherever the copy is placed.

function lovr.conf(t)
  t.identity = 'lunette'

  -- LÖVR defaults this to true (vendor/lovr/etc/boot.lua). The default mounts
  -- the save directory ahead of everything else, so a file written there
  -- shadows a same-named file elsewhere. The precedence exists to patch a
  -- packaged application. A session that writes 'mullion/init.lua' or
  -- 'main.lua' into its save directory replaces the standard library or the
  -- configuration for every session after it, and no reload can undo it
  -- because the reload reads the shadowing copy too. Setting it to false
  -- leaves the save directory mounted and readable. The save directory then
  -- no longer shadows a same-named file.
  t.saveprecedence = false

  t.headset.backend = 'auto'
  t.headset.overlay = true

  -- boot.lua provides a populated window table of its own
  -- (vendor/lovr/etc/boot.lua) and opens a window whenever conf.window is
  -- set. These fields customise the default table. Setting t.window = nil
  -- prevents the window from opening.
  t.window.title = 'lunette'
  t.window.width = 1280
  t.window.height = 800
  t.window.resizable = true
end

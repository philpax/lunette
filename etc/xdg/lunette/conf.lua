-- The default lunette configuration.
--
-- lunette loads this directory when the user has none of their own. Copy it to
-- $XDG_CONFIG_HOME/lunette and edit it there.

function lovr.conf(t)
  t.identity = 'lunette'

  -- boot.lua ships a populated window table of its own
  -- (vendor/lovr/etc/boot.lua:63-71) and opens a window whenever conf.window is
  -- set (:171), so these fields customise the default rather than enable it.
  -- Setting t.window = nil is what suppresses the window.
  t.window.title = 'lunette'
  t.window.width = 1280
  t.window.height = 800
  t.window.resizable = true
end

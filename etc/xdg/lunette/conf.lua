-- The default lunette configuration.
--
-- lunette loads this directory when the user has none of their own. Copy it to
-- $XDG_CONFIG_HOME/lunette and edit it there.

function lovr.conf(t)
  t.identity = 'lunette'

  -- The desktop simulator only opens a window when this table is set, so
  -- omitting it gives a running process with no visible output.
  t.window.title = 'lunette'
  t.window.width = 1280
  t.window.height = 800
  t.window.resizable = true
end

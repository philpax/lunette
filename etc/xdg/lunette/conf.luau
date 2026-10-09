-- This directory is the default configuration when no user configuration exists.

function lovr.conf(t)
  t.identity = 'lunette'

  -- Save-directory precedence can shadow packaged modules and `main.luau` across sessions. Disabling it keeps the directory readable without overriding packaged files.
  t.saveprecedence = false

  t.headset.backend = 'auto'
  t.headset.overlay = true

  -- LÖVR opens a desktop window when this configuration supplies a window table. Set `t.window` to nil to disable it.
  t.window.title = 'lunette'
  t.window.width = 1280
  t.window.height = 800
  t.window.resizable = true
end

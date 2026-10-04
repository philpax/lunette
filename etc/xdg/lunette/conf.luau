-- This directory is the default configuration when no user configuration exists.

function lovr.conf(t)
  t.identity = 'lunette'

  -- Save-directory precedence can shadow packaged modules and `main.luau` across sessions. Disabling it keeps the directory readable without overriding packaged files.
  t.saveprecedence = false

  -- A truthy value requests `XR_EXTX_overlay` and shares the primary application's session. A number also sets `sessionLayersPlacement`; `true` uses placement 0.
  -- The extension enables alpha composition, so undrawn areas reveal the application beneath the overlay.
  t.headset.overlay = true

  -- LÖVR opens a desktop window when this configuration supplies a window table. Set `t.window` to nil to disable it.
  t.window.title = 'lunette'
  t.window.width = 1280
  t.window.height = 800
  t.window.resizable = true
end

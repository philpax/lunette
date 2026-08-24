-- The default lunette configuration.

function lovr.conf(t)
  t.identity = 'lunette'

  -- Keep the save directory readable without letting it shadow the standard
  -- library or configuration.
  t.saveprecedence = false

  -- Run as an XR overlay and leave undrawn areas transparent.
  t.headset.overlay = true

  -- Customise the default window.
  t.window.title = 'lunette'
  t.window.width = 1280
  t.window.height = 800
  t.window.resizable = true
end

-- The default lunette configuration.
--
-- lunette loads this directory when the user has none of their own. Copy it to
-- $XDG_CONFIG_HOME/lunette and edit it there.

function lovr.conf(t)
  t.identity = 'lunette'

  -- lunette is an overlay, not an application. Setting this requests
  -- XR_EXTX_overlay (vendor/lovr/src/modules/headset/headset.c:509) and chains
  -- XrSessionCreateInfoOverlayEXTX into session creation (:1032-1041), so the
  -- runtime lets lunette share a session with whatever holds the primary one
  -- rather than refusing to create a second.
  --
  -- The value is read once (src/api/l_headset.c:1141-1143): any truthy value
  -- enables the extension, and a number also becomes sessionLayersPlacement,
  -- which orders lunette against other overlays. There is no separate
  -- overlayOrder key. `true` leaves the placement at 0.
  --
  -- Enabling the extension is also what makes the frame transparent:
  -- headset.c:3067-3071 sets XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT
  -- on the projection layer whenever the extension is enabled, so areas Lua does
  -- not draw composite through to the application underneath.
  t.headset.overlay = true

  -- boot.lua ships a populated window table of its own
  -- (vendor/lovr/etc/boot.lua:63-71) and opens a window whenever conf.window is
  -- set (:171), so these fields customise the default rather than enable it.
  -- Setting t.window = nil is what suppresses the window.
  t.window.title = 'lunette'
  t.window.width = 1280
  t.window.height = 800
  t.window.resizable = true
end

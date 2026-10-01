-- The default lunette configuration.
--
-- lunette loads this directory when the user has none of their own. Run
-- `lunette --dump-config` to put a copy in $XDG_CONFIG_HOME/lunette and edit it
-- there. The copy is `main.luau` and this file: the desktop itself is the
-- installed `@lunette-desktop` root, which `main.luau` composes and patches. The
-- command writes a `.luaurc` naming this installation's Lua roots, which makes
-- `lunette check` and an editor resolve `@lunette-desktop`, `@lunette`, and the
-- other installed roots from wherever the copy is placed.

function lovr.conf(t)
  t.identity = 'lunette'

  -- LÖVR defaults this to true (vendor/lovr/etc/boot.lua). The default mounts
  -- the save directory ahead of everything else, so a file written there
  -- shadows a same-named file elsewhere. The precedence exists to patch a
  -- packaged application. A session that writes '@lunette-desktop/init.luau'
  -- or 'main.luau' into its save directory replaces the desktop or the
  -- configuration for every session after it, and no reload can undo it
  -- because the reload reads the shadowing copy too. Setting it to false
  -- leaves the save directory mounted and readable. The save directory then
  -- no longer shadows a same-named file.
  t.saveprecedence = false

  -- lunette runs as an OpenXR overlay. Setting this requests XR_EXTX_overlay
  -- (vendor/lovr/src/modules/headset/headset.c) and chains
  -- XrSessionCreateInfoOverlayEXTX into session creation. lunette then shares a
  -- session with the application holding the primary session. Without the
  -- extension, the runtime does not create a second session.
  --
  -- The value is read once (src/api/l_headset.c): any truthy value enables the
  -- extension, and a number also becomes sessionLayersPlacement, which orders
  -- lunette against other overlays. There is no separate overlayOrder key.
  -- `true` leaves the placement at 0.
  --
  -- The extension also makes the frame transparent. headset.c sets
  -- XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT on the projection
  -- layer whenever the extension is enabled, so areas that Lua does not draw
  -- composite through to the application underneath.
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

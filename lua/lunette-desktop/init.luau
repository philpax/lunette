-- The shipped desktop composes its plugin entries with configuration patches and starts them through the frame provider.

local plugin = require '@lunette-plugin'
local frame = require '@lunette-plugins/session/frame'
local theme = require '@lunette-plugins/theme/resolver'
local themeCatalog = require '@lunette-plugins/theme/catalog'
local standardThemes = require '@lunette-plugins/theme/standard'
local arcadeTheme = require '@lunette-plugins/theme/arcade'
local themeSelector = require '@lunette-plugins/theme/selector'
local surfaces = require '@lunette-plugins/interaction/surfaces'
local panels = require '@lunette-plugins/panels/service'
local drops = require '@lunette-plugins/interaction/drops'
local focus = require '@lunette-plugins/input/focus'
local bindings = require '@lunette-plugins/input/bindings'
local interaction = require '@lunette-plugins/interaction/pointers'
local laser = require '@lunette-plugins/input/laser'
local keyboard = require '@lunette-plugins/input/keyboard'
local ui = require '@lunette-plugins/ui/toolkit'
local uiHost = require '@lunette-plugins/ui/host'
local uiStandard = require '@lunette-plugins/ui/standard'
local notifications = require '@lunette-plugins/ui/notifications'
local accessibilityProvider = require '@lunette-plugins/ui/accessibility'
local accessibilitySettings = require '@lunette-plugins/ui/accessibility-settings'
local menu = require '@lunette-plugins/menu/action-registry'
local tags = require '@lunette-plugins/workspace/tags'
local rules = require '@lunette-plugins/window/rule-resolver'
local placement = require '@lunette-plugins/window/placement'
local adoption = require '@lunette-plugins/window/adoption'
local layouts = require '@lunette-plugins/layout/catalog'
local arc = require '@lunette-plugins/layout/arc'
local errorStream = require '@lunette-plugins/diagnostics/error-stream'
local pacingProvider = require '@lunette-plugins/pacing/service'
local scaleProvider = require '@lunette-plugins/scale/service'
local audio = require '@lunette-plugins/audio/capture'
local audioAnalysis = require '@lunette-plugins/audio/analysis'
local render = require '@lunette-plugins/panels/renderer'
local backdrop = require '@lunette-plugins/environment/backdrop'
local monitors = require '@lunette-plugins/panels/monitors'
local hint = require '@lunette-plugins/environment/empty-desktop-hint'
local decorations = require '@lunette-plugins/panels/decorations'
local pointing = require '@lunette-plugins/input/hand-pointers'
local input = require '@lunette-plugins/input/physical-routing'
local keyboardDisplay = require '@lunette-plugins/input/keyboard-display'
local wristMenu = require '@lunette-plugins/menu/wrist-menu'
local actions = require '@lunette-plugins/session/menu-actions'
local errors = require '@lunette-plugins/diagnostics/error-display'
local workspaces = require '@lunette-plugins/workspace/controller'
local defaultRules = require '@lunette-plugins/window/configured-rules'
local arrangement = require '@lunette-plugins/layout/persistence'
local arrange = require '@lunette-plugins/layout/arrange'
local adoptionConsumer = require '@lunette-plugins/window/adoption-controller'
local pacing = require '@lunette-plugins/pacing/controller'
local scale = require '@lunette-plugins/scale/output-controller'
local manager = require '@lunette-plugins/session/plugin-manager'
local settings = require '@lunette-desktop/settings'
local management = require '@lunette-plugin/management'

local desktop = {}

export type Keyboard = keyboard.Board
export type RenderedKey = keyboard.RenderedKey

type Options = {
  read patches: { plugin.Patch }?,
  read settings: settings.Config?,
}

local OPTION_KEYS: { string } = { 'patches', 'settings' }

-- Persistence and arrangement use factories to preserve state across activations. Rule sources precede adoption so they resolve the first window.
local DEFAULT: { plugin.Entry } = plugin.compose {
  { id = 'frame', definition = frame.definition },
  { id = 'theme', definition = theme.definition },
  { id = 'themes', definition = themeCatalog.definition },
  { id = 'theme/standard', definition = standardThemes.definition },
  { id = 'theme/arcade', definition = arcadeTheme.definition },
  { id = 'surfaces', definition = surfaces.definition },
  { id = 'panels', definition = panels.definition },
  { id = 'drops', definition = drops.definition },
  { id = 'focus', definition = focus.definition },
  { id = 'bindings', definition = bindings.definition },
  { id = 'interaction', definition = interaction.definition },
  { id = 'laser', definition = laser.definition },
  { id = 'keyboard', definition = keyboard.definition },
  { id = 'ui', definition = ui.definition },
  { id = 'ui-host', definition = uiHost.definition },
  { id = 'ui-standard', definition = uiStandard.definition },
  { id = 'notifications', definition = notifications.definition },
  { id = 'accessibility', definition = accessibilityProvider.definition },
  { id = 'menu', definition = menu.definition },
  { id = 'desktop/theme', definition = themeSelector.definition },
  { id = 'tags', definition = tags.definition },
  { id = 'rules', definition = rules.definition },
  { id = 'placement', definition = placement.definition },
  { id = 'adoption', definition = adoption.definition },
  { id = 'layouts', definition = layouts.definition },
  { id = 'layout/arc', definition = arc.definition },
  { id = 'errors', definition = errorStream.definition },
  { id = 'pacing', definition = pacingProvider.definition },
  { id = 'scale', definition = scaleProvider.definition },
  { id = 'audio', definition = audio.definition },
  { id = 'audio-analysis', definition = audioAnalysis.definition },
  { id = 'desktop/render', definition = render.definition },
  { id = 'desktop/hint', definition = hint.definition },
  { id = 'desktop/decorations', definition = decorations.definition },
  { id = 'desktop/pointing', definition = pointing.definition },
  { id = 'desktop/input', definition = input.definition },
  { id = 'desktop/keyboard', definition = keyboardDisplay.definition },
  { id = 'desktop/menu', definition = wristMenu.definition },
  { id = 'desktop/actions', definition = actions.definition },
  { id = 'desktop/errors', definition = errors.definition },
  { id = 'desktop/workspaces', definition = workspaces.definition },
  { id = 'desktop/monitors', definition = monitors.definition },
  { id = 'desktop/rules', definition = defaultRules.definition },
  { id = 'desktop/persistence', definition = arrangement.definition },
  { id = 'desktop/arrange', definition = arrange.definition },
  { id = 'desktop/adoption', definition = adoptionConsumer.definition },
  { id = 'desktop/pacing', definition = pacing.definition },
  { id = 'desktop/scale', definition = scale.definition },
  { id = 'desktop/backdrop', definition = backdrop.definition },
  { id = 'desktop/manager', definition = manager.definition },
  { id = 'desktop/accessibility', definition = accessibilitySettings.definition },
}

-- Each setting becomes one configuration patch after the given ones, so one composition rejects a setting and a patch
-- naming one id.
local function patchesFor(options: Options): { plugin.Patch }?
  local given = options.settings
  local extra = options.patches
  if given == nil or (extra ~= nil and type(extra) ~= 'table') then
    return extra
  end
  settings.schema.parse(given, 'desktop settings')
  -- The given keys are copied unchanged so that composition still reports a malformed patch list by position.
  local patches: { [unknown]: unknown } = {}
  local last = 0
  for key, patch in (extra or {}) :: { [unknown]: unknown } do
    patches[key] = patch
    if type(key) == 'number' and key > last then
      last = key
    end
  end
  for id, config in given :: { [string]: unknown } do
    last += 1
    patches[last] = { id = id, config = config }
  end
  return (patches :: unknown) :: { plugin.Patch }
end

-- Returns the patched entries, which start in list order. Composition rejects unknown fields, duplicate ids, and two patches naming one id.
function desktop.compose(options: Options?): { plugin.Entry }
  if options == nil then
    return DEFAULT
  end
  plugin.rejectUnknownFields('desktop: the options', options, OPTION_KEYS, 0)
  return plugin.compose(DEFAULT, patchesFor(options))
end

-- Composition errors occur while the configuration loads, before LÖVR callbacks are bound.
function desktop.run(options: Options?): ()
  local entries = desktop.compose(options)
  local protected: { string } = {}
  for _, entry in entries do
    if
      entry.id == 'desktop/manager'
      or entry.id == 'desktop/menu'
      or entry.id == 'desktop/keyboard'
      or entry.id == 'desktop/pointing'
      or entry.id == 'desktop/actions'
    then
      protected[#protected + 1] = entry.id
    end
  end
  local running: management.Running? = nil
  frame.install {
    start = function(): ()
      if not running then
        running = management.start(entries, { protected = protected })
      end
    end,
    stop = function(): ()
      local current = running
      running = nil
      if current then
        current.runtime:close()
      end
    end,
  }
end

return desktop

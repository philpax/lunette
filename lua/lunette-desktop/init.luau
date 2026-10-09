-- The shipped desktop composes its plugin entries with configuration patches and starts them through the frame provider.

local plugin = require '@lunette-plugin'
local frame = require '@lunette-plugins/frame'
local theme = require '@lunette-plugins/theme'
local themeCatalog = require '@lunette-plugins/themes'
local standardThemes = require '@lunette-plugins/theme/standard'
local arcadeTheme = require '@lunette-plugins/theme/arcade'
local themeSelector = require '@lunette-plugins/desktop/theme'
local surfaces = require '@lunette-plugins/surfaces'
local panels = require '@lunette-plugins/panels'
local drops = require '@lunette-plugins/drops'
local focus = require '@lunette-plugins/focus'
local bindings = require '@lunette-plugins/bindings'
local interaction = require '@lunette-plugins/interaction'
local laser = require '@lunette-plugins/laser'
local keyboard = require '@lunette-plugins/keyboard'
local ui = require '@lunette-plugins/ui'
local menu = require '@lunette-plugins/menu'
local tags = require '@lunette-plugins/tags'
local rules = require '@lunette-plugins/rules'
local placement = require '@lunette-plugins/placement'
local adoption = require '@lunette-plugins/adoption'
local layouts = require '@lunette-plugins/layouts'
local arc = require '@lunette-plugins/layout/arc'
local errorStream = require '@lunette-plugins/errors'
local pacingProvider = require '@lunette-plugins/pacing'
local scaleProvider = require '@lunette-plugins/scale'
local render = require '@lunette-plugins/desktop/render'
local monitors = require '@lunette-plugins/desktop/monitors'
local hint = require '@lunette-plugins/desktop/hint'
local decorations = require '@lunette-plugins/desktop/decorations'
local pointing = require '@lunette-plugins/desktop/pointing'
local input = require '@lunette-plugins/desktop/input'
local keyboardDisplay = require '@lunette-plugins/keyboard-display'
local wristMenu = require '@lunette-plugins/desktop/menu'
local actions = require '@lunette-plugins/desktop/actions'
local errors = require '@lunette-plugins/desktop/errors'
local workspaces = require '@lunette-plugins/desktop/workspaces'
local defaultRules = require '@lunette-plugins/desktop/rules'
local arrangement = require '@lunette-plugins/arrangement'
local arrange = require '@lunette-plugins/desktop/arrange'
local adoptionConsumer = require '@lunette-plugins/desktop/adoption'
local pacing = require '@lunette-plugins/desktop/pacing'
local scale = require '@lunette-plugins/desktop/scale'
local manager = require '@lunette-plugins/desktop/manager'
local settings = require '@lunette-desktop/settings'
local management = require '@lunette-plugin/management'

local desktop = {}

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
  { id = 'desktop/manager', definition = manager.definition },
}

-- Entries start in list order.
function desktop.entries(): { plugin.Entry }
  return DEFAULT
end

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

-- Returns the patched entries. Composition rejects unknown fields, duplicate ids, and two patches naming one id.
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

-- The shipped desktop composes its plugin entries with configuration patches and starts them through the frame provider.

local plugin = require '@lunette-plugin'
local frame = require '@lunette-plugins/frame'
local surfaces = require '@lunette-plugins/surfaces'
local panels = require '@lunette-plugins/panels'
local drops = require '@lunette-plugins/drops'
local focus = require '@lunette-plugins/focus'
local bindings = require '@lunette-plugins/bindings'
local interaction = require '@lunette-plugins/interaction'
local laser = require '@lunette-plugins/laser'
local keyboard = require '@lunette-plugins/keyboard'
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
local desktopBindings = require '@lunette-plugins/desktop/bindings'
local wristKeyboard = require '@lunette-plugins/desktop/keyboard'
local errors = require '@lunette-plugins/desktop/errors'
local workspace = require '@lunette-plugins/desktop/workspace'
local defaultRules = require '@lunette-plugins/desktop/rules'
local poseMemory = require '@lunette-plugins/desktop/pose-memory'
local arrangement = require '@lunette-plugins/arrangement'
local arrange = require '@lunette-plugins/desktop/arrange'
local adoptionConsumer = require '@lunette-plugins/desktop/adoption'
local demoTerminal = require '@lunette-plugins/desktop/demo-terminal'
local pacing = require '@lunette-plugins/desktop/pacing'
local scale = require '@lunette-plugins/desktop/scale'

local desktop = {}

export type Entry = plugin.Entry
export type Patch = plugin.Patch

export type Options = {
  read entries: { Entry }?,
  read patches: { Patch }?,
}

local OPTION_KEYS: { [string]: boolean } = { entries = true, patches = true }

-- Persistence and arrangement use factories to preserve state across activations. Rule sources precede adoption so they resolve the first window.
local DEFAULT: { Entry } = plugin.compose {
  { id = 'frame', definition = frame.definition },
  { id = 'surfaces', definition = surfaces.definition },
  { id = 'panels', definition = panels.definition },
  { id = 'drops', definition = drops.definition },
  { id = 'focus', definition = focus.definition },
  { id = 'bindings', definition = bindings.definition },
  { id = 'interaction', definition = interaction.definition },
  { id = 'laser', definition = laser.definition },
  { id = 'keyboard', definition = keyboard.definition },
  { id = 'tags', definition = tags.definition },
  { id = 'rules', definition = rules.definition },
  { id = 'placement', definition = placement.definition },
  { id = 'adoption', definition = adoption.definition },
  { id = 'layouts', definition = layouts.definition },
  { id = 'layout/arc', definition = arc.definition },
  { id = 'errors', definition = errorStream.definition },
  { id = 'pacing', definition = pacingProvider.definition },
  { id = 'scale', definition = scaleProvider.definition },
  { id = 'desktop/render', definition = render },
  { id = 'desktop/hint', definition = hint },
  { id = 'desktop/decorations', definition = decorations },
  { id = 'desktop/pointing', definition = pointing },
  { id = 'desktop/input', definition = input },
  { id = 'desktop/bindings', definition = desktopBindings },
  { id = 'desktop/keyboard', definition = wristKeyboard },
  { id = 'desktop/errors', definition = errors },
  { id = 'desktop/workspace', definition = workspace },
  { id = 'desktop/monitors', definition = monitors },
  { id = 'desktop/rules', definition = defaultRules },
  { id = 'desktop/pose-memory', definition = poseMemory },
  { id = 'desktop/persistence', factory = arrangement.factory },
  { id = 'desktop/arrange', factory = arrange },
  { id = 'desktop/adoption', definition = adoptionConsumer },
  { id = 'desktop/demo-terminal', definition = demoTerminal },
  { id = 'desktop/pacing', definition = pacing },
  { id = 'desktop/scale', definition = scale },
}

-- The returned configuration function checks values against the definition's options.
desktop.configure = plugin.configure

-- Entries start in list order, and the list and its entries are frozen.
function desktop.entries(): { Entry }
  return DEFAULT
end

-- Returns patched entries and rejects unknown fields, duplicate ids, and conflicting patches.
function desktop.compose(options: Options?): { Entry }
  if options == nil then
    return DEFAULT
  end
  plugin.rejectUnknownFields('desktop: the options', options, OPTION_KEYS, 'entries and patches', 0)
  return plugin.compose(options.entries or DEFAULT, options.patches)
end

-- Composition errors occur while the configuration loads, before LÖVR callbacks are bound.
function desktop.run(options: Options?): ()
  frame.run(desktop.compose(options))
end

return desktop

-- The shipped desktop: its plugins as a list of entries. `run` composes them with a configuration's patches
-- and starts them through the frame provider. A configuration calls `run`:
--
--   require('@lunette-desktop').run { patches = { { id = 'keyboard', disabled = true } } }

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
local render = require '@lunette-desktop/render'
local monitors = require '@lunette-desktop/monitors'
local hint = require '@lunette-desktop/hint'
local decorations = require '@lunette-desktop/decorations'
local pointing = require '@lunette-desktop/pointing'
local input = require '@lunette-desktop/input'
local desktopBindings = require '@lunette-desktop/bindings'
local wristKeyboard = require '@lunette-desktop/keyboard'
local errors = require '@lunette-desktop/errors'
local workspace = require '@lunette-desktop/workspace'
local defaultRules = require '@lunette-desktop/rules'
local poseMemory = require '@lunette-desktop/pose-memory'
local persistence = require '@lunette-desktop/persistence'
local arrange = require '@lunette-desktop/arrange'
local adoptionConsumer = require '@lunette-desktop/adoption'
local demoTerminal = require '@lunette-desktop/demo-terminal'
local pacing = require '@lunette-desktop/pacing'
local scale = require '@lunette-desktop/scale'

local desktop = {}

export type Entry = plugin.Entry
export type Patch = plugin.Patch

-- What `compose` and `run` take: the entries to start from, by default the shipped desktop's, and the
-- patches to apply to them.
export type Options = {
  read entries: { Entry }?,
  read patches: { Patch }?,
}

local OPTION_KEYS: { [string]: boolean } = { entries = true, patches = true }

-- Each entry's id is its definition's name. Persistence and arrangement are factories, because their state
-- outlives their activations. The rule list and saved arrangement must be rules sources before adoption
-- resolves the first window; no other entry depends on order.
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
  { id = 'desktop/persistence', factory = persistence },
  { id = 'desktop/arrange', factory = arrange },
  { id = 'desktop/adoption', definition = adoptionConsumer },
  { id = 'desktop/demo-terminal', definition = demoTerminal },
  { id = 'desktop/pacing', definition = pacing },
  { id = 'desktop/scale', definition = scale },
}

-- A typed patch for each shipped entry that takes options, answering `{ id = <entry id>, config = ... }`.
-- A plain patch list's config cannot be typed per id, so `desktop.configure.laser { style = ... }` is what
-- gets checked. An id with a slash is indexed as a string: `desktop.configure['desktop/arrange'] { ... }`.
export type Configure = {
  read panels: (panels.Config) -> Patch,
  read interaction: (interaction.Config) -> Patch,
  read laser: (laser.Config) -> Patch,
  read keyboard: (keyboard.Config) -> Patch,
  read rules: (rules.Config) -> Patch,
  read placement: (placement.Config) -> Patch,
  read adoption: (adoption.Config) -> Patch,
  read ['layout/arc']: (arc.Config) -> Patch,
  read errors: (errorStream.Config) -> Patch,
  read pacing: (pacingProvider.Config) -> Patch,
  read scale: (scaleProvider.Config) -> Patch,
  read ['desktop/hint']: (hint.Config) -> Patch,
  read ['desktop/decorations']: (decorations.Config) -> Patch,
  read ['desktop/pointing']: (pointing.Config) -> Patch,
  read ['desktop/bindings']: (desktopBindings.Config) -> Patch,
  read ['desktop/keyboard']: (wristKeyboard.Config) -> Patch,
  read ['desktop/errors']: (errors.Config) -> Patch,
  read ['desktop/workspace']: (workspace.Config) -> Patch,
  read ['desktop/monitors']: (monitors.Config) -> Patch,
  read ['desktop/rules']: (defaultRules.Config) -> Patch,
  read ['desktop/persistence']: (persistence.Config) -> Patch,
  read ['desktop/arrange']: (arrange.Config) -> Patch,
  read ['desktop/adoption']: (adoptionConsumer.Config) -> Patch,
  read ['desktop/demo-terminal']: (demoTerminal.Config) -> Patch,
  read ['desktop/pacing']: (pacing.Config) -> Patch,
}

local function configure<C>(id: string): (C) -> Patch
  return function(config: C): Patch
    return { id = id, config = config :: any }
  end
end

desktop.configure = table.freeze {
  panels = configure<<panels.Config>> 'panels',
  interaction = configure<<interaction.Config>> 'interaction',
  laser = configure<<laser.Config>> 'laser',
  keyboard = configure<<keyboard.Config>> 'keyboard',
  rules = configure<<rules.Config>> 'rules',
  placement = configure<<placement.Config>> 'placement',
  adoption = configure<<adoption.Config>> 'adoption',
  ['layout/arc'] = configure<<arc.Config>> 'layout/arc',
  errors = configure<<errorStream.Config>> 'errors',
  pacing = configure<<pacingProvider.Config>> 'pacing',
  scale = configure<<scaleProvider.Config>> 'scale',
  ['desktop/hint'] = configure<<hint.Config>> 'desktop/hint',
  ['desktop/decorations'] = configure<<decorations.Config>> 'desktop/decorations',
  ['desktop/pointing'] = configure<<pointing.Config>> 'desktop/pointing',
  ['desktop/bindings'] = configure<<desktopBindings.Config>> 'desktop/bindings',
  ['desktop/keyboard'] = configure<<wristKeyboard.Config>> 'desktop/keyboard',
  ['desktop/errors'] = configure<<errors.Config>> 'desktop/errors',
  ['desktop/workspace'] = configure<<workspace.Config>> 'desktop/workspace',
  ['desktop/monitors'] = configure<<monitors.Config>> 'desktop/monitors',
  ['desktop/rules'] = configure<<defaultRules.Config>> 'desktop/rules',
  ['desktop/persistence'] = configure<<persistence.Config>> 'desktop/persistence',
  ['desktop/arrange'] = configure<<arrange.Config>> 'desktop/arrange',
  ['desktop/adoption'] = configure<<adoptionConsumer.Config>> 'desktop/adoption',
  ['desktop/demo-terminal'] = configure<<demoTerminal.Config>> 'desktop/demo-terminal',
  ['desktop/pacing'] = configure<<pacing.Config>> 'desktop/pacing',
} :: Configure

-- The shipped desktop's entries, in the order they are enabled. The list and
-- every entry in it are frozen.
function desktop.entries(): { Entry }
  return DEFAULT
end

-- Answers the entries, by default the shipped desktop's, with the patches applied, raising for an unknown or
-- duplicate id, an unknown field, or conflicting patches.
function desktop.compose(options: Options?): { Entry }
  if options == nil then
    return DEFAULT
  end
  plugin.rejectUnknownFields('desktop: the options', options, OPTION_KEYS, 'entries and patches', 2)
  return plugin.compose(options.entries or DEFAULT, options.patches)
end

-- Composes the desktop and binds LÖVR's callbacks to it. The composition is checked as the configuration
-- loads, so a malformed patch fails the load rather than the first frame.
function desktop.run(options: Options?): ()
  local entries = desktop.compose(options)
  -- Source reload retains globals, so desktop/demo-terminal does not open
  -- another terminal after a reload.
  _G.lunetteDemonstrationSpawned = _G.lunetteDemonstrationSpawned or false
  frame.run(entries)
end

return desktop

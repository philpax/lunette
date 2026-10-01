-- The shipped desktop: its plugins as a list of entries, and the run that
-- binds LÖVR's callbacks and starts them.
--
-- `entries` answers the default list, read-only, so a configuration can see
-- the ids it patches. `compose` applies patches to a list. `start` makes a
-- runtime and enables a list's entries in it. `run` does both from LÖVR's
-- callbacks and is what a configuration calls:
--
--   require('@lunette-desktop').run { patches = { { id = 'keyboard', disabled = true } } }

local plugin = require '@lunette-plugin'
local compose = require '@lunette-desktop/compose'
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

local desktop = {}

export type Entry = compose.Entry
export type Patch = compose.Patch
export type Options = compose.Options
export type Config = compose.Config
export type Definition = compose.Definition

-- A started desktop: its runtime, and the instance made for each entry, by id.
export type Running = {
  read runtime: plugin.Runtime,
  read instances: { read [string]: plugin.Instance<any> },
}

-- Each entry's id is its definition's name. Persistence and arrangement are
-- factories: the state each keeps outlives its own activations, and starting a
-- runtime makes a new one.
--
-- The order is the order entries are enabled in, and the order the graph
-- loads them again after an outage of something they share. The rule list
-- and the saved arrangement are rules sources before adoption resolves the
-- first window, which is the one order the placement entries rely on. Tags
-- are held rather than made, so the workspace tag does not depend on the
-- workspace entry coming first, and the arrangement arranges what was
-- placed before it activated.
local DEFAULT: { Entry } = compose.apply({
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
}, nil)

-- A typed patch for each shipped entry that takes options: a function of the
-- entry's own Config type answering `{ id = <entry id>, config = <options> }`.
-- `desktop.configure.laser { style = ... }` is checked against the laser's
-- options where `{ id = 'laser', config = { ... } }` is checked against
-- nothing, because a patch list mixes entries and its config field cannot be
-- typed per id. An id with a slash is indexed as a string:
-- `desktop.configure['desktop/arrange'] { layout = 'arc' }`. The options are
-- validated again when the entry loads, which is what reports a field Luau
-- does not flag, such as a misspelt key in a table literal.
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
} :: Configure

-- The shipped desktop's entries, in the order they are enabled. The list and
-- every entry in it are frozen.
function desktop.entries(): { Entry }
  return DEFAULT
end

-- Answers the entries, by default the shipped desktop's, with the patches
-- applied. Raises an error naming the id for an unknown id, a duplicate id, an
-- unknown field, or conflicting patches.
function desktop.compose(options: Options?): { Entry }
  return compose.apply(DEFAULT, options)
end

-- Makes a runtime, uses and enables every entry in order, calling each
-- factory once, and drains the runtime. A failure closes the runtime and is
-- raised. A configuration error is a plugin's own failure: the instance
-- fails to load and its error is reported, as for any other initializer.
function desktop.start(entries: { Entry }): Running
  local checked = compose.apply(entries, nil)
  local runtime = plugin.runtime()
  local instances: { [string]: plugin.Instance<any> } = {}
  local ok, failure = pcall(function(): ()
    for _, entry in ipairs(checked) do
      local factory = entry.factory
      local definition = entry.definition or (factory and factory())
      if type(definition) ~= 'table' then
        error('desktop: the factory of ' .. entry.id .. ' answered a ' .. type(definition) .. ', not a definition', 0)
      end
      local instance = runtime:use(definition, entry.config or {})
      instances[entry.id] = instance
      instance:enable()
    end
    runtime:drain()
  end)
  if not ok then
    runtime:close()
    error(failure, 0)
  end
  return table.freeze { runtime = runtime, instances = table.freeze(instances) }
end

-- Composes the desktop and binds LÖVR's callbacks to it: lovr.load starts it,
-- and lovr.quit runs its quit handlers and then closes it. The composition is
-- checked here, as the configuration loads, so a malformed patch fails the
-- load rather than the first frame.
function desktop.run(options: Options?): ()
  local entries = desktop.compose(options)
  -- Source reload retains globals, so desktop/demo-terminal does not open
  -- another terminal after a reload.
  _G.lunetteDemonstrationSpawned = _G.lunetteDemonstrationSpawned or false
  local running: Running? = nil
  frame.install {
    start = function(): ()
      if running then
        return
      end
      running = desktop.start(entries)
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

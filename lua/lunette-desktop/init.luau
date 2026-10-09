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
local keyboardDisplay = require '@lunette-plugins/desktop/keyboard'
local wristMenu = require '@lunette-plugins/desktop/menu'
local actions = require '@lunette-plugins/desktop/actions'
local errors = require '@lunette-plugins/desktop/errors'
local workspace = require '@lunette-plugins/desktop/workspace'
local workspaces = require '@lunette-plugins/desktop/workspaces'
local defaultRules = require '@lunette-plugins/desktop/rules'
local poseMemory = require '@lunette-plugins/desktop/pose-memory'
local arrangement = require '@lunette-plugins/arrangement'
local arrange = require '@lunette-plugins/desktop/arrange'
local adoptionConsumer = require '@lunette-plugins/desktop/adoption'
local pacing = require '@lunette-plugins/desktop/pacing'
local scale = require '@lunette-plugins/desktop/scale'
local manager = require '@lunette-plugins/desktop/manager'
local settings = require '@lunette-desktop/settings'
local workspacesConfig = require '@lunette-plugins/desktop/workspaces/config'
local management = require '@lunette-plugin/management'

local desktop = {}

export type Entry = plugin.Entry
export type Patch = plugin.Patch

export type Settings = settings.Config

export type Options = {
  read entries: { Entry }?,
  read patches: { Patch }?,
  read settings: Settings?,
  read workspaces: workspaces.Config?,
}

local OPTION_KEYS: { [string]: boolean } = { entries = true, patches = true, settings = true, workspaces = true }
local SETTING_IDS: { [string]: string } = {
  menu = 'desktop/menu',
  decorations = 'desktop/decorations',
  arrange = 'desktop/arrange',
  persistence = 'desktop/persistence',
  wristKeyboard = 'desktop/keyboard',
  rules = 'desktop/rules',
  monitors = 'desktop/monitors',
  hint = 'desktop/hint',
  errors = 'desktop/errors',
  pointing = 'desktop/pointing',
  pacing = 'desktop/pacing',
  workspace = 'desktop/workspace',
  adoption = 'desktop/adoption',
  manager = 'desktop/manager',
}
local SETTING_KEYS: { [string]: boolean } = {}
for name, _ in SETTING_IDS do
  SETTING_KEYS[name] = true
end
local SETTING_FIELDS =
  'menu, decorations, arrange, persistence, wristKeyboard, rules, monitors, hint, errors, pointing, pacing, workspace, adoption, and manager'

-- Persistence and arrangement use factories to preserve state across activations. Rule sources precede adoption so they resolve the first window.
local DEFAULT: { Entry } = plugin.compose {
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
  { id = 'desktop/theme', factory = themeSelector },
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
  { id = 'desktop/keyboard', definition = keyboardDisplay },
  { id = 'desktop/menu', definition = wristMenu },
  { id = 'desktop/actions', definition = actions },
  { id = 'desktop/errors', definition = errors },
  { id = 'desktop/workspace', definition = workspace },
  { id = 'desktop/monitors', definition = monitors },
  { id = 'desktop/rules', definition = defaultRules },
  { id = 'desktop/pose-memory', definition = poseMemory },
  { id = 'desktop/persistence', factory = arrangement.factory },
  { id = 'desktop/arrange', factory = arrange },
  { id = 'desktop/adoption', definition = adoptionConsumer },
  { id = 'desktop/pacing', definition = pacing },
  { id = 'desktop/scale', definition = scale },
  { id = 'desktop/manager', definition = manager },
}

-- The returned configuration functions check values against the definition's options.
desktop.configure = plugin.configure

-- Entries start in list order, and the list and its entries are frozen.
function desktop.entries(): { Entry }
  return DEFAULT
end

type Raw = { [unknown]: unknown }

local function expanded(options: Options, entries: { Entry }): ({ Patch }, { [string]: string })
  local patches: { Patch } = {}
  local sources: { [string]: string } = {}
  local function claim(id: string, source: string): ()
    local previous = sources[id]
    if previous then
      error('desktop: ' .. source .. ' and ' .. previous .. ' both configure ' .. id .. '; use one source', 0)
    end
    sources[id] = source
  end
  if options.settings ~= nil then
    local raw = (options.settings :: unknown) :: Raw
    if type(raw) == 'table' then
      if raw.bindings ~= nil then
        error('desktop: settings.bindings is removed; session actions use the wrist menu', 0)
      end
      if type(raw.manager) == 'table' and rawget(raw.manager :: Raw, 'toggleKey') ~= nil then
        error('desktop: manager.toggleKey is removed; open Plugins from the session menu', 0)
      end
      if type(raw.wristKeyboard) == 'table' then
        local keyboardConfig = raw.wristKeyboard :: Raw
        for _, field in { 'hand', 'size', 'offset', 'haptic' } do
          if rawget(keyboardConfig, field) ~= nil then
            error('desktop: wristKeyboard.' .. field .. ' is removed; configure settings.menu instead', 0)
          end
        end
      end
    end
    plugin.rejectUnknownFields('desktop: the settings', options.settings, SETTING_KEYS, SETTING_FIELDS, 0)
    settings.schema.parse(options.settings, 'desktop settings')
    for name, config in options.settings :: any do
      local id = SETTING_IDS[name]
      claim(id, 'settings.' .. name)
      patches[#patches + 1] = { id = id, config = config }
    end
  end
  if options.workspaces ~= nil then
    local config = options.workspaces
    local raw = (config :: unknown) :: Raw
    if type(raw) == 'table' and raw.modifiers ~= nil then
      error('desktop: workspaces.modifiers is removed; workspaces use menu actions', 0)
    end
    plugin.rejectUnknownFields(
      'desktop: workspaces',
      config,
      { workspaces = true, follow = true },
      'workspaces and follow',
      0
    )
    local resolved = workspacesConfig.schema.parse(config, 'desktop workspaces')
    local initial = resolved.workspaces[1].name
    for _, id in ipairs { 'desktop/workspaces', 'desktop/workspace', 'desktop/adoption' } do
      claim(id, 'workspaces')
      for _, entry in ipairs(entries) do
        if entry.id == id and (id == 'desktop/workspaces' or entry.config ~= nil) then
          error(
            'desktop: workspaces and the configured entry ' .. id .. ' both configure ' .. id .. '; use raw patches',
            0
          )
        end
      end
    end
    patches[#patches + 1] = { id = 'desktop/workspace', config = { name = initial } }
    patches[#patches + 1] = { id = 'desktop/adoption', config = { tags = { initial } } }
    patches[#patches + 1] = {
      insert = { id = 'desktop/workspaces', definition = workspaces, config = config :: any },
      before = 'desktop/adoption',
    }
  end
  return patches, sources
end

-- Returns patched entries and rejects unknown fields, duplicate ids, and conflicting patches.
function desktop.compose(options: Options?): { Entry }
  if options == nil then
    return DEFAULT
  end
  plugin.rejectUnknownFields(
    'desktop: the options',
    options,
    OPTION_KEYS,
    'entries, patches, settings, and workspaces',
    0
  )
  local entries = plugin.compose(options.entries or DEFAULT)
  local patches, sources = expanded(options, entries)
  local configured = plugin.compose(entries, patches)
  if type(options.patches) == 'table' then
    for index, patch in pairs(options.patches) do
      if type(patch) == 'table' then
        local raw = (patch :: unknown) :: Raw
        local id = raw.id
        if type(raw.insert) == 'table' then
          id = (raw.insert :: Raw).id
        end
        if type(id) == 'string' and sources[id] then
          error(
            'desktop: patch '
              .. tostring(index)
              .. ' and '
              .. sources[id]
              .. ' both configure '
              .. id
              .. '; use one source',
            0
          )
        end
      end
    end
  end
  return plugin.compose(configured, options.patches)
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

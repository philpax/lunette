-- Selects a theme from the catalog by name and retains the session's choice across activations of one factory
-- definition. A missing choice falls back to the configured name, and to no selection when that is missing too.

local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local menu = require '@lunette-contracts/menu'
local theme = require '@lunette-contracts/theme'
local themes = require '@lunette-contracts/themes'
local descriptors = require '@lunette-plugins/theme/descriptors'
local logging = require '@lunette-plugins/desktop/logging'
local config = require '@lunette-plugins/desktop/theme/config'

export type Config = config.Config
export type Settings = config.Settings

local required: plugin.Declaration = {
  frame.capability,
  menu.capability,
  theme.capability,
  themes.capability,
}

type Action = {
  registration: menu.Registration,
  order: number,
}

local function define(): plugin.Definition<Config>
  local chosen: string? = nil
  local configuredPreset: string? = nil
  return plugin.consumer<<Config, Settings>>({
    name = 'desktop/theme',
    requires = required,
    schema = config.schema,
    init = function(context: plugin.Context, settings: Settings): ()
      local frameService: frame.Service = context:require(frame.capability)
      local menuService: menu.Service = context:require(menu.capability)
      local themeService: theme.Service = context:require(theme.capability)
      local catalog: themes.Service = context:require(themes.capability)
      local overrides = descriptors.projectOverrides(settings.overrides, 'desktop/theme overrides')
      local wanted = if chosen ~= nil and configuredPreset == settings.preset then chosen else settings.preset
      local registration: theme.Registration? = nil
      local applied: themes.Entry? = nil
      local revision = 0
      local actions: { [string]: Action } = {}
      local reported: { [string]: boolean } = {}

      local function effective(): themes.Entry?
        return catalog:get(wanted) or catalog:get(settings.preset)
      end

      -- A raise leaves the previous selection in place. A nested change made while the theme service notifies wins.
      local function show(entry: themes.Entry?): boolean
        local before = revision
        local current = registration
        if entry == nil then
          if current then
            registration = nil
            current:dispose()
          end
        else
          local value = descriptors.resolve(entry.theme, overrides)
          if current then
            current:update(value)
          else
            registration = themeService:select(context, value)
          end
        end
        if not context:active() or revision ~= before then
          return false
        end
        revision += 1
        applied = entry
        return true
      end

      local function isApplied(name: string): boolean
        local entry = applied
        return entry ~= nil and entry.name == name
      end

      local function mark(): ()
        for name, action in actions do
          action.registration:update { selected = isApplied(name) }
        end
      end

      local function choose(name: string): ()
        if not context:active() then
          return
        end
        local entry = catalog:get(name)
        if entry == nil then
          error('desktop/theme: ' .. name .. ' is no longer a registered theme', 0)
        end
        if show(entry) then
          wanted, chosen = name, name
          mark()
        end
      end

      -- Choices follow the catalog's order. A name returns only after its removal, which disposes its action, so only a
      -- changed position replaces a live one.
      local function sync(): ()
        local present: { [string]: boolean } = {}
        for index, entry in catalog:list() do
          local name = entry.name
          local label = 'Theme: ' .. entry.label
          present[name] = true
          local action = actions[name]
          if action and action.order ~= index then
            actions[name] = nil
            action.registration:dispose()
            action = nil
          end
          if action == nil then
            actions[name] = {
              order = index,
              registration = menuService:register(context, {
                id = 'desktop/theme/' .. name,
                label = label,
                group = 'Appearance',
                order = index,
                selected = isApplied(name),
                run = function(): ()
                  choose(name)
                end,
              }),
            }
          end
        end
        for name, action in actions do
          if not present[name] then
            actions[name] = nil
            action.registration:dispose()
          end
        end
      end

      catalog:onChanged(context, {
        run = function(): ()
          if not context:active() then
            return
          end
          sync()
          local entry = effective()
          if entry ~= applied and show(entry) then
            mark()
          end
        end,
      })

      -- Reporting waits for a frame so that themes registered by later entries are not reported as missing.
      frameService:onUpdate(context, {
        phase = 'scene',
        run = function(): ()
          for _, name in { wanted, settings.preset } do
            if catalog:get(name) then
              reported[name] = nil
            elseif not reported[name] then
              reported[name] = true
              local names: { string } = {}
              for _, entry in catalog:list() do
                names[#names + 1] = entry.name
              end
              local known = if #names == 0
                then 'no theme is registered'
                else 'the registered themes are ' .. table.concat(names, ', ')
              logging.report('desktop/theme: ' .. name .. ' is not a registered theme; ' .. known, 'warn')
            end
          end
        end,
      })

      sync()
      show(effective())
      mark()
      chosen, configuredPreset = wanted, settings.preset
    end,
  }).definition
end

return define

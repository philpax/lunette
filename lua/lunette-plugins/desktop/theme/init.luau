-- Selects a runtime theme and retains the session's preset across activations of one factory definition.

local plugin = require '@lunette-plugin'
local menu = require '@lunette-contracts/menu'
local theme = require '@lunette-contracts/theme'
local descriptors = require '@lunette-plugins/theme/descriptors'
local presets = require '@lunette-plugins/theme/presets'
local config = require '@lunette-plugins/desktop/theme/config'

export type Config = config.Config
export type Settings = config.Settings
export type Preset = config.Preset

local required: plugin.Declaration = {
  menu = menu.capability,
  theme = theme.capability,
}
local themes: { read [Preset]: theme.Theme } = {
  dark = presets.dark,
  light = presets.light,
  arcade = presets.arcade,
}
local choices: { read [number]: { read preset: Preset, read label: string } } = {
  { preset = 'dark', label = 'Theme: Dark' },
  { preset = 'light', label = 'Theme: Light' },
  { preset = 'arcade', label = 'Theme: Arcade' },
}

local function define(): plugin.Definition<Config>
  local selected: Preset? = nil
  local configuredPreset: Preset? = nil
  return plugin.consumer<<Config, Settings>>({
    name = 'desktop/theme',
    requires = required,
    schema = config.schema,
    init = function(context: plugin.Context, settings: Settings): ()
      local themeService: theme.Service = context:require(theme.capability)
      local menuService: menu.Service = context:require(menu.capability)
      local initial = if selected ~= nil and configuredPreset == settings.preset then selected else settings.preset
      local overrides = descriptors.projectOverrides(settings.overrides, 'desktop/theme overrides')
      local registration = themeService:select(context, descriptors.resolve(themes[initial], overrides))
      local actions: { [Preset]: plugin.Effect } = {}
      local darkMode: plugin.Effect? = nil
      local choiceRevision = 0

      local function choose(preset: Preset): ()
        if not context:active() then
          return
        end
        local before = choiceRevision
        registration:update(descriptors.resolve(themes[preset], overrides))
        if not context:active() or choiceRevision ~= before then
          return
        end
        choiceRevision += 1
        selected = preset
        for name, effect in actions do
          menuService:update(context, effect, { selected = name == preset })
        end
        if darkMode then
          menuService:update(context, darkMode, { selected = preset == 'dark' })
        end
      end

      for index, choice in choices do
        local preset = choice.preset
        actions[preset] = menuService:register(context, {
          id = 'desktop/theme/' .. preset,
          label = choice.label,
          group = 'Appearance',
          order = index,
          selected = initial == preset,
          run = function(): ()
            choose(preset)
          end,
        })
      end
      darkMode = menuService:register(context, {
        id = 'desktop/theme/dark-mode',
        label = 'Dark mode',
        group = 'Appearance',
        order = #choices + 1,
        selected = initial == 'dark',
        run = function(): ()
          choose(if selected == 'dark' then 'light' else 'dark')
        end,
      })
      selected, configuredPreset = initial, settings.preset
    end,
  }).definition
end

return define

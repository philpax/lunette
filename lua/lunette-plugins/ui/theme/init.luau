-- Provides the session's theme: the lunette palette resolved for a mode, an accent, and the accessibility options.
local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/theme'
local listeners = require '@lunette-plugins/registration/listeners'
local settingsFile = require '@lunette-plugins/storage/settings-file'
local config = require '@self/config'
local palette = require '@self/private/palette'

export type Config = config.Config
export type Settings = config.Settings

local function freeze(color: contract.Color): contract.Color
  return table.freeze { color[1], color[2], color[3], color[4] or 1 }
end

local CHECKS: { [string]: settingsFile.Check } = {
  mode = function(value: any): boolean
    return value == 'dark' or value == 'light'
  end,
  accent = function(value: any): boolean
    if type(value) ~= 'table' or #value < 3 or #value > 4 then
      return false
    end
    for _, component in value do
      if type(component) ~= 'number' or not (component >= 0 and component <= 1) then
        return false
      end
    end
    return true
  end,
}

local function build(context: plugin.Context, settings: Settings): contract.Service
  -- The configured mode and accent are the defaults; choices saved in a session replace them.
  local spec: settingsFile.Spec = {
    path = settings.file,
    label = 'theme: settings',
    version = 1,
    checks = CHECKS,
    defaults = {
      mode = settings.mode,
      accent = if settings.accent then table.clone(settings.accent) else table.clone(palette.DEFAULT_ACCENT),
    },
  }
  local opened = settingsFile.open(spec)
  local mode: contract.Mode = opened.file.settings.mode
  local accent = freeze(opened.file.settings.accent)
  local options: contract.Options = {}
  local current = palette.resolve(mode, accent, options)
  local base = palette.resolve('dark', palette.DEFAULT_ACCENT, options)
  local changed = listeners.new<<(contract.Theme) -> ()>>(context)

  local function save(): ()
    opened.file.settings.mode = mode
    opened.file.settings.accent = { accent[1], accent[2], accent[3], accent[4] }
    settingsFile.save(spec, opened)
  end

  local function resolve(): ()
    current = palette.resolve(mode, accent, options)
    base = palette.resolve('dark', palette.DEFAULT_ACCENT, options)
    local resolved = current
    changed:each('theme: a change listener', function(run: (contract.Theme) -> ()): ()
      run(resolved)
    end)
  end

  context:effect(function(): () -> ()
    return function(): ()
      changed:clear()
    end
  end)

  return {
    current = function(_self: contract.Service): contract.Theme
      return current
    end,
    base = function(_self: contract.Service): contract.Theme
      return base
    end,
    setMode = function(_self: contract.Service, given: contract.Mode): ()
      assert(given == 'dark' or given == 'light', `theme: '{tostring(given)}' is not a mode`)
      if given ~= mode then
        mode = given
        save()
        resolve()
      end
    end,
    accent = function(_self: contract.Service): contract.Color
      return accent
    end,
    setAccent = function(_self: contract.Service, given: contract.Color): ()
      assert(CHECKS.accent(given), 'theme: an accent is three or four components from 0 to 1')
      accent = freeze(given)
      save()
      resolve()
    end,
    setOptions = function(_self: contract.Service, given: contract.Options): ()
      assert(type(given) == 'table', 'theme: options are a table')
      local scale = given.textScale
      assert(
        scale == nil or (type(scale) == 'number' and scale >= 0.5 and scale <= 2),
        'theme: a text scale is from 0.5 to 2'
      )
      if given.textScale ~= options.textScale or given.highContrast ~= options.highContrast then
        options = table.freeze { textScale = given.textScale, highContrast = given.highContrast }
        resolve()
      end
    end,
    onChanged = function(
      _self: contract.Service,
      owner: contract.Owner,
      listener: { read run: (contract.Theme) -> () }
    ): plugin.Effect
      context:checkOwner(owner)
      assert(type(listener) == 'table' and type(listener.run) == 'function', 'theme: a listener has a run function')
      return changed:add(owner, listener.run)
    end,
  }
end

return plugin.provider<<Config, Settings, contract.Service>> {
  name = 'theme',
  capability = contract.capability,
  schema = config.schema,
  build = build,
}

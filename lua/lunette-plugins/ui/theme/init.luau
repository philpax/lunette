-- Provides the session's theme: the lunette palette resolved for a mode, an accent, and the accessibility options.
local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/theme'
local listeners = require '@lunette-plugins/registration/listeners'
local config = require '@self/config'
local palette = require '@self/private/palette'

export type Config = config.Config
export type Settings = config.Settings

local function freeze(color: contract.Color): contract.Color
  return table.freeze { color[1], color[2], color[3], color[4] or 1 }
end

local function build(context: plugin.Context, settings: Settings): contract.Service
  local mode: contract.Mode = settings.mode
  local accent = if settings.accent then freeze(settings.accent) else palette.DEFAULT_ACCENT
  local options: contract.Options = {}
  local current = palette.resolve(mode, accent, options)
  local base = palette.resolve('dark', palette.DEFAULT_ACCENT, options)
  local changed = listeners.new<<(contract.Theme) -> ()>>(context)

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
        context:save { mode = given }
        resolve()
      end
    end,
    accent = function(_self: contract.Service): contract.Color
      return accent
    end,
    setAccent = function(_self: contract.Service, given: contract.Color): ()
      assert(type(given) == 'table' and #given >= 3 and #given <= 4, 'theme: an accent is three or four components')
      for _, component in given do
        assert(type(component) == 'number' and component >= 0 and component <= 1, 'theme: a component is from 0 to 1')
      end
      accent = freeze(given)
      context:save { accent = { accent[1], accent[2], accent[3], accent[4] } }
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

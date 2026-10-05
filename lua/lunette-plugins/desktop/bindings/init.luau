-- Registers the reload chord before key delivery. Configured chords replace F5.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local bindings = require '@lunette-contracts/bindings'
local logging = require '@lunette-plugins/desktop/logging'

local config = require '@lunette-plugins/desktop/bindings/config'

export type Config = config.Config
export type Settings = config.Settings

local required: plugin.Declaration = { bindings = bindings.capability }

return plugin.consumer<<Config, Settings>>({
  name = 'desktop/bindings',
  requires = required,
  schema = config.schema,
  init = function(context: plugin.Context, settings: Settings): ()
    local service: bindings.Service = context:require(bindings.capability)
    service:register(context, {
      chord = settings.reload,
      run = function(_press: bindings.Press): ()
        local reloaded, message = lunette.reload()
        if not reloaded then
          logging.report('configuration was not reloaded: ' .. tostring(message), 'error')
        end
      end,
    })
  end,
}).definition

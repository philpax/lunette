-- The desktop's own key bindings: `reload`, F5 unless configured, registered with the bindings broker so it
-- is consumed before any key reaches a client.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local bindings = require '@lunette-contracts/bindings'
local logging = require '@lunette-plugins/desktop/logging'

-- What a configuration gives: every option optional.
export type Config = {
  read reload: {
    read key: KeyCode?,
    read modifiers: { string }?,
  }?,
}

export type Settings = {
  read reload: {
    read key: KeyCode,
    read modifiers: { string },
  },
}

local DEFAULTS: Settings = { reload = { key = 'f5', modifiers = {} } }

local required: plugin.Declaration = { bindings = bindings.capability }

return plugin.define {
  name = 'desktop/bindings',
  requires = required,
  init = function(context: plugin.Context, config: Config, _publish: plugin.Publisher): ()
    local settings: Settings = plugin.options { name = 'desktop/bindings', defaults = DEFAULTS, config = config }
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
}

-- Optional error presentation; native logging remains independent.
local plugin = require '@lunette-plugin'
local display = require '@lunette-contracts/error-display'
local callbackModule = require '../desktop/callbacks'
export type Config = { read callbacks: typeof(callbackModule) }
local required: plugin.Declaration = { display = display.capability }

return plugin.define {
  name = 'desktop/errors',
  requires = required,
  init = function(context: plugin.Context, config: Config, _publish: plugin.Publisher): ()
    local callbacks = config.callbacks
    local service: display.Service = context:require(display.capability)
    callbacks.onDraw(context, function(pass: Pass)
      service:draw(pass)
    end, 400)
  end,
}

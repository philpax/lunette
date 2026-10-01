-- Optional error presentation; native logging remains independent.
local plugin = require '@lunette-plugin'
local display = require '@lunette-contracts/error-display'
local frame = require '@lunette-contracts/frame'
local required: plugin.Declaration = { display = display.capability, frame = frame.capability }

return plugin.define {
  name = 'desktop/errors',
  requires = required,
  init = function(context: plugin.Context, config: {}, _publish: plugin.Publisher): ()
    -- The consumer takes no options, so any option is a mistake worth naming.
    plugin.options { name = 'desktop/errors', defaults = {}, config = config }
    local frameService: frame.Service = context:require(frame.capability)
    local service: display.Service = context:require(display.capability)
    frameService:onDraw(context, {
      phase = 'overlay',
      run = function(pass: Pass)
        service:draw(pass)
      end,
    })
  end,
}

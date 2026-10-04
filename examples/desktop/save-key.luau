-- Control, Alt, and S save the arrangement. Control, Alt, and R restore it through the configured arrangement provider.
local plugin = require '@lunette-plugin'
local arrangement = require '@lunette-contracts/arrangement'
local bindings = require '@lunette-contracts/bindings'

return plugin.define {
  name = 'save-key',
  requires = { arrangement = arrangement.capability, bindings = bindings.capability },
  init = function(context: plugin.Context, _config: {}, _publish: plugin.Publisher)
    local saved: arrangement.Service = context:require(arrangement.capability)
    local keys: bindings.Service = context:require(bindings.capability)
    keys:register(context, {
      chord = { key = 's', modifiers = { 'control', 'alt' } },
      run = function(_press: bindings.Press)
        local written, message = saved:save()
        local log = lovr.log
        if not written and log then
          log('the arrangement was not saved: ' .. tostring(message), 'warn', 'save-key')
        end
      end,
    })
    keys:register(context, {
      chord = { key = 'r', modifiers = { 'control', 'alt' } },
      run = function(_press: bindings.Press)
        saved:restore()
      end,
    })
  end,
}

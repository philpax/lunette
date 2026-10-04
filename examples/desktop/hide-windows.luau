-- Control, Alt, and H toggle owner-scoped visibility overrides. Disposing this plugin's overrides preserves hidden state owned by other plugins.
local plugin = require '@lunette-plugin'
local bindings = require '@lunette-contracts/bindings'
local panels = require '@lunette-contracts/panels'

return plugin.define {
  name = 'hide-windows',
  requires = { bindings = bindings.capability, panels = panels.capability },
  init = function(context: plugin.Context, _config: {}, _publish: plugin.Publisher)
    local keys: bindings.Service = context:require(bindings.capability)
    local panelService: panels.Service = context:require(panels.capability)
    local overrides: { plugin.Effect } = {}
    keys:register(context, {
      chord = { key = 'h', modifiers = { 'control', 'alt' } },
      run = function(_press: bindings.Press)
        if #overrides > 0 then
          for _, override in ipairs(overrides) do
            override:dispose()
          end
          table.clear(overrides)
          return
        end
        for _, panel in ipairs(panelService:all()) do
          if panel.kind == 'window' then
            overrides[#overrides + 1] = panel:setHidden(context, { hidden = true })
          end
        end
      end,
    })
  end,
}

-- Registers the desktop rule list as a source; configured rules replace the default list.
local plugin = require '@lunette-plugin'
local rules = require '@lunette-contracts/rules'

export type Config = {
  read rules: { rules.Rule }?,
}

export type Settings = {
  read rules: { rules.Rule },
}

local DEFAULTS: Settings = {
  rules = {
    {
      match = { appId = 'firefox' },
      properties = {
        width = 2,
        pose = function(): Mat4
          return lovr.math.newMat4():translate(-1.4, 1.5, -1.2):rotate(0.9, 0, 1, 0)
        end,
      },
    },
  },
}

local required: plugin.Declaration = { rules = rules.capability }

return plugin.define {
  name = 'desktop/rules',
  requires = required,
  init = function(context: plugin.Context, config: Config, _publish: plugin.Publisher): ()
    local settings: Settings = plugin.options { name = 'desktop/rules', defaults = DEFAULTS, config = config }
    local service: rules.Service = context:require(rules.capability)
    service:setRules(context, { rules = settings.rules })
  end,
}

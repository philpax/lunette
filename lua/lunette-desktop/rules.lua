-- The desktop's rule list, registered as a rules source.
--
-- `rules` is the list, which replaces the default list wholesale rather than
-- merging with it. It is registered under the rules provider's default source
-- name and precedence, so a plugin that registers a rule list of its own names
-- it. The default list sizes and places Firefox.
local plugin = require '@lunette-plugin'
local rules = require '@lunette-contracts/rules'

-- What a configuration gives: every option optional.
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

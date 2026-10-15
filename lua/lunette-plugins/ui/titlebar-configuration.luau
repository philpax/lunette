-- Projects editable titlebar configuration into detached, sparse contract values.
local schema = require '@lunette-plugin/schema'
local ui = require '@lunette-contracts/ui'
local titlebarStyle = require '@lunette-contracts/schemas/titlebar-style'
local themeConfiguration = require '@lunette-plugins/theme/configuration'

local configuration = {}
configuration.editable = schema.object(titlebarStyle.fields(themeConfiguration.editableFont))

function configuration.project(value: unknown): ui.TitlebarStyleOverrides
  local parsed = configuration.editable.parse(value, 'ui titlebar configuration')
  local result = table.clone(parsed) :: { [string]: unknown }
  result.font = if parsed.font then themeConfiguration.projectFont(parsed.font) else nil
  return titlebarStyle.schema.parse(result, 'ui titlebar style')
end

return table.freeze(configuration)

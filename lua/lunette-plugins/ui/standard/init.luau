-- Registers the standard kinds, their visuals, and the theme's fonts, and publishes their constructors.

local plugin = require '@lunette-plugin'
local lunette = require '@lunette'
local uiHost = require '@lunette-contracts/ui-host'
local uiComponents = require '@lunette-contracts/ui-components'
local structure = require '@self/private/structure'
local display = require '@self/private/display'
local actions = require '@self/private/actions'
local choices = require '@self/private/choices'
local values = require '@self/private/values'
local collections = require '@self/private/collections'
local overlays = require '@self/private/overlays'
local fields = require '@self/private/fields'
local scrollView = require '@self/private/scroll-view'
local markdown = require '@self/private/markdown'

local FONTS = {
  '@lunette-plugins/ui/standard/fonts/IBMPlexSans-Regular.ttf',
  '@lunette-plugins/ui/standard/fonts/IBMPlexSans-Medium.ttf',
  '@lunette-plugins/ui/standard/fonts/IBMPlexSans-SemiBold.ttf',
  '@lunette-plugins/ui/standard/fonts/Iosevka-Regular.ttf',
}

local function build(context: plugin.Context): uiComponents.Service
  local host = context:require(uiHost.capability)
  for _, file in FONTS do
    local data = lovr.filesystem.read(file)
    assert(type(data) == 'string', `ui: the font '{file}' could not be read`)
    lunette.loadLayoutFont(data)
  end
  local constructors: { [string]: uiHost.Constructor } = {}
  for _, family in { display, structure, actions, choices, values, collections, overlays, fields, markdown, scrollView } do
    for name, constructor in family.register(host, context) do
      assert(constructors[name] == nil, `ui standard: {name} is registered twice`)
      constructors[name] = constructor
    end
  end
  return table.freeze(constructors) :: any
end

return plugin.provider<<{}, {}, uiComponents.Service>> {
  name = 'ui-standard',
  capability = uiComponents.capability,
  requires = { uiHost.capability },
  build = function(context: plugin.Context): uiComponents.Service
    return build(context)
  end,
}

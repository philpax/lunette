local lunette = require '@lunette'
local ui = require '@lunette-contracts/ui'
local provider = require '@lunette-plugins/ui'
local menu = require '@lunette-contracts/menu'
local menuProvider = require '@lunette-plugins/menu'
local display = require '@lunette-contracts/keyboard-display'
local displayProvider = require '@lunette-plugins/desktop/keyboard'
local theme = require '@lunette-contracts/theme'
local themeProvider = require '@lunette-plugins/theme'
local themeSelector = require '@lunette-plugins/desktop/theme'
local themes = require '@lunette-contracts/themes'
local themeCatalog = require '@lunette-plugins/themes'
local arcadeTheme = require '@lunette-plugins/theme/arcade'

local definition = provider.definition
local requires = provider.requires
local variant = provider.define { theme = { fontSize = 18 } }

local function inspect(service: ui.Service): { read [number]: ui.Panel }
  local boundaries: { number } = lunette.textBoundaries ''
  assert(#boundaries == 1 and boundaries[1] == 1)
  return service:panels()
end

local function sessionControls(actions: menu.Service, board: display.Service): boolean
  local rows: { read [number]: menu.Descriptor } = actions:list()
  return #rows == 0 and not board:isVisible()
end

return {
  definition,
  requires,
  variant,
  inspect,
  menuProvider.definition,
  displayProvider,
  sessionControls,
  theme.capability,
  themeProvider.definition,
  themeSelector,
  themes.capability,
  themeCatalog.definition,
  arcadeTheme.definition,
}

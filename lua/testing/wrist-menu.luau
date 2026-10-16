-- Runs menu actions through the wrist menu as a controller does: open the menu, click the action's row, and close it.

local uiHost = require '@lunette-contracts/ui-host'
local uiPanels = require '@testing/ui-panels'
local vrUi = require '@testing/vr-ui'

local wristMenu = {}

wristMenu.PANEL = 'desktop/menu'

-- The key path of an action's row in the open menu.
function wristMenu.row(id: string): string
  return 'actions/' .. uiHost.keyOf(id)
end

function wristMenu.open(fixture: vrUi.Fixture, panels: uiPanels.Recorder, hand: vrUi.Hand?): ()
  panels:click(fixture, wristMenu.PANEL, 'open', hand)
end

function wristMenu.close(fixture: vrUi.Fixture, panels: uiPanels.Recorder, hand: vrUi.Hand?): ()
  panels:click(fixture, wristMenu.PANEL, 'header/band/close', hand)
end

-- Opens the menu, clicks the action, and closes the menu again when the action left it open.
function wristMenu.run(fixture: vrUi.Fixture, panels: uiPanels.Recorder, id: string, hand: vrUi.Hand?): ()
  wristMenu.open(fixture, panels, hand)
  panels:click(fixture, wristMenu.PANEL, wristMenu.row(id), hand)
  if panels:node(wristMenu.PANEL, 'header/band/close') then
    wristMenu.close(fixture, panels, hand)
  end
end

return wristMenu

-- Runs menu actions through the wrist menu as a controller does: open the menu, click the action's row, and close it.

local uiHost = require '@lunette-contracts/ui-host'
local uiPanels = require '@testing/ui-panels'
local vrUi = require '@testing/vr-ui'

local wristMenu = {}

-- The gauntlet on the wrist, and the list its menu button opens.
wristMenu.PANEL = 'desktop/menu'
wristMenu.LIST = 'desktop/menu/list'

-- The key path of an action's row in the open menu.
function wristMenu.row(id: string): string
  return 'actions/' .. uiHost.keyOf(id)
end

-- A wrist pose from which the menu, at its default offset, faces a head at the fixtures' default pose. The menu fades
-- as it turns away from the head, so a wrist held edge-on to it shows nothing to press.
function wristMenu.facingPose(): Mat4
  return lovr.math.newMat4():translate(-0.125, 1.5, -0.43):rotate(math.pi / 2, 0, 1, 0)
end

-- Turns the menu's wrist, the hand opposite the pointing one, towards the head and waits until the menu can be
-- pressed. A menu that can already be pressed, such as one torn off the wrist, stays as it is.
function wristMenu.face(fixture: vrUi.Fixture, panels: uiPanels.Recorder, hand: vrUi.Hand?): ()
  if panels:pressable(wristMenu.PANEL) then
    return
  end
  local wrist: vrUi.Hand = if hand == 'left' then 'right' else 'left'
  fixture:pose(wrist, wristMenu.facingPose())
  fixture:tracked(wrist, true)
  for _ = 1, 60 do
    if panels:pressable(wristMenu.PANEL) then
      return
    end
    fixture:step()
  end
  error 'wrist-menu: the menu does not become pressable when it faces the head'
end

-- Opens the menu, which may already be open: the menu stays open across a reload.
function wristMenu.open(fixture: vrUi.Fixture, panels: uiPanels.Recorder, hand: vrUi.Hand?): ()
  wristMenu.face(fixture, panels, hand)
  if panels:pressable(wristMenu.LIST) then
    return
  end
  panels:click(fixture, wristMenu.PANEL, 'open', hand)
end

function wristMenu.close(fixture: vrUi.Fixture, panels: uiPanels.Recorder, hand: vrUi.Hand?): ()
  wristMenu.face(fixture, panels, hand)
  panels:click(fixture, wristMenu.LIST, 'header/band/close', hand)
end

-- Opens the menu, clicks the action, and closes the menu again when the action left it open.
function wristMenu.run(fixture: vrUi.Fixture, panels: uiPanels.Recorder, id: string, hand: vrUi.Hand?): ()
  wristMenu.open(fixture, panels, hand)
  panels:click(fixture, wristMenu.LIST, wristMenu.row(id), hand)
  if panels:pressable(wristMenu.LIST) then
    wristMenu.close(fixture, panels, hand)
  end
end

return wristMenu

local lunette = require '@lunette'
local ui = require '@lunette-contracts/ui'
local surface = require '@lunette-contracts/surface'

local function onPointer(event: surface.PointerEvent): ()
  local button: lunette.PointerButton? = event.button -- reject.
  if event.kind == 'move' then
    local requiredButton: lunette.PointerButton = event.button -- reject.
    assert(requiredButton ~= 'back')
  elseif event.kind == 'scroll' then
    local invalidButton: lunette.PointerButton? = event.button -- reject.
    assert(invalidButton == button)
  elseif event.kind == 'release' then
    local reason: surface.CancelReason = event.reason -- reject.
    assert(reason ~= 'grab')
  elseif event.kind == 'enter' then
    local dx: number = event.dx -- reject.
    assert(dx == dx)
  end
end

local function region(panel: ui.Panel, owner: ui.Owner): ui.Region
  return panel:region(owner, {
    id = 'wrong-pointer-region',
    bounds = { x = 0, y = 0, width = 100, height = 100 },
    onPointer = function(_event: ui.Visual): () end, -- reject.
  })
end

return { onPointer, region }

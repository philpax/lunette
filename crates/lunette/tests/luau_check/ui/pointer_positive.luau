local lunette = require '@lunette'
local ui = require '@lunette-contracts/ui'
local vocabulary = require '@lunette-contracts/vocabulary'

local function onPointer(event: vocabulary.PointerEvent): ()
  if event.kind == 'press' then
    local button: lunette.PointerButton = event.button
    assert(button ~= 'back')
  elseif event.kind == 'release' then
    local button: lunette.PointerButton = event.button
    assert(button ~= 'forward')
  elseif event.kind == 'scroll' then
    local dx: number = event.dx
    local dy: number = event.dy
    assert(dx == dx and dy == dy)
  elseif event.kind == 'cancel' then
    local reason: vocabulary.CancelReason = event.reason
    local button: lunette.PointerButton = event.button
    assert(reason ~= 'grab' or button ~= 'left')
  else
    local x: number? = event.x
    assert(x == nil or x == x)
  end
end

local function region(panel: ui.Panel, owner: ui.Owner): ui.Region
  return panel:region(owner, {
    id = 'pointer-region',
    bounds = { x = 0, y = 0, width = 100, height = 100 },
    onPointer = onPointer,
  })
end

return region

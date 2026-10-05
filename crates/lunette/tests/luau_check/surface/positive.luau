local lunette = require '@lunette'
local surface = require '@lunette-contracts/surface'
local interaction = require '@lunette-contracts/interaction'

type SurfaceMetadata = { read dead: boolean, read width: number? }
type PointerMetadata = { read dead: boolean, read distance: number? }

local function inspectEvent(event: interaction.PointerEvent): ()
  local pointer: interaction.Pointer = event.pointer
  local x: number? = event.x
  local y: number? = event.y
  local captured: boolean = event.captured
  local inside: boolean = event.inside
  assert(not pointer.dead or captured or not inside)
  assert(x == nil or x >= 0)
  assert(y == nil or y >= 0)

  if event.kind == 'enter' then
    local kind: 'enter' = event.kind
    assert(kind == 'enter')
  elseif event.kind == 'leave' then
    local kind: 'leave' = event.kind
    assert(kind == 'leave')
  elseif event.kind == 'move' then
    local button: lunette.PointerButton? = event.button
    assert(button == nil or button ~= 'left')
  elseif event.kind == 'press' then
    local button: lunette.PointerButton = event.button
    assert(button ~= 'back')
  elseif event.kind == 'release' then
    local button: lunette.PointerButton = event.button
    assert(button ~= 'forward')
  elseif event.kind == 'scroll' then
    local dx: number = event.dx
    local dy: number = event.dy
    assert(dx ~= dy)
  elseif event.kind == 'cancel' then
    local button: lunette.PointerButton = event.button
    local reason: interaction.CancelReason = event.reason
    assert(button ~= 'forward' or reason ~= 'grab')
  end
end

local function genericReceiver<T>(_self: T, event: surface.PointerEvent): ()
  inspectEvent(event)
end

local function legacySurface(): surface.Surface
  return {
    kind = nil,
    dead = false,
    raycast = function(
      _self: surface.Surface,
      _origin: vector,
      _direction: vector,
      _captured: boolean?
    ): (number?, number?, number?)
      return nil, nil, nil
    end,
    onHover = function(_self: surface.Surface, _x: number?, _y: number?, _pointer: surface.Pointer): () end,
    onLeave = function(_self: surface.Surface, _pointer: surface.Pointer): () end,
    onPress = function(_self: surface.Surface, _x: number?, _y: number?, _pointer: surface.Pointer): () end,
    onRelease = function(_self: surface.Surface, _pointer: surface.Pointer): () end,
  }
end

local function protocolSurface(): interaction.Surface
  return {
    kind = nil,
    dead = false,
    raycast = function(
      _self: interaction.Surface,
      _origin: vector,
      _direction: vector,
      _captured: boolean?
    ): (number?, number?, number?)
      return nil, nil, nil
    end,
    project = function(_self: interaction.Surface, _origin: vector, _direction: vector): (number?, number?, number?)
      return nil, nil, nil
    end,
    onPointer = genericReceiver,
  }
end

local function inspectSurface(target: surface.Surface, pointer: surface.Pointer): ()
  local surfaceMetadata: SurfaceMetadata = target
  local pointerMetadata: PointerMetadata = pointer
  local dead: boolean = surfaceMetadata.dead or pointerMetadata.dead
  local width: number? = surfaceMetadata.width
  local distance: number? = pointerMetadata.distance
  pointer:cancel(target, 'grab')
  assert(dead or width == nil or distance == nil)
end

local function exerciseEvents(pointer: surface.Pointer): { surface.PointerEvent }
  local enter: surface.PointerEvent = {
    kind = 'enter',
    pointer = pointer,
    x = 0,
    y = 0,
    captured = false,
    inside = true,
  }
  local leave: interaction.PointerEvent = {
    kind = 'leave',
    pointer = pointer,
    x = 1,
    y = 1,
    captured = false,
    inside = false,
  }
  local move: interaction.PointerEvent = {
    kind = 'move',
    pointer = pointer,
    x = 2,
    y = 2,
    captured = true,
    inside = true,
    button = 'left',
  }
  local press: interaction.PointerEvent = {
    kind = 'press',
    pointer = pointer,
    x = 3,
    y = 3,
    captured = false,
    inside = true,
    button = 'right',
  }
  local release: surface.PointerEvent = {
    kind = 'release',
    pointer = pointer,
    x = 4,
    y = 4,
    captured = false,
    inside = false,
    button = 'middle',
  }
  local scroll: interaction.PointerEvent = {
    kind = 'scroll',
    pointer = pointer,
    x = 5,
    y = 5,
    captured = false,
    inside = true,
    dx = 1,
    dy = -1,
  }
  local cancel: surface.PointerEvent = {
    kind = 'cancel',
    pointer = pointer,
    x = 6,
    y = 6,
    captured = true,
    inside = false,
    button = 'back',
    reason = 'tracking-loss',
  }

  for _, event in { enter, leave, move, press, release, scroll, cancel } do
    inspectEvent(event)
  end
  return { enter, leave, move, press, release, scroll, cancel }
end

return { inspectSurface, exerciseEvents, legacySurface, protocolSurface }

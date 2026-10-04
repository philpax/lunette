-- Each owner offers and draws its own keyboards. Release failures belong to the keyboard owner.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local focus = require '@lunette-contracts/focus'
local keyboard = require '@lunette-contracts/keyboard'
local keyVocabulary = require '@lunette-contracts/keys'
local quad = require '@lunette-contracts/quad'
local board = require '@lunette-plugins/keyboard/board'
local drawing = require '@lunette-plugins/keyboard/draw'
local layout = require '@lunette-plugins/keyboard/layout'
local validation = require '@lunette-plugins/keyboard/validation'

local CHARACTER = '[%z\1-\127\194-\244][\128-\191]*'

export type Settings = {
  read rows: { keyboard.KeyRow },
  read layers: { [string]: { keyboard.KeyRow } },
  read style: keyboard.Style,
  read modifierKeys: { [number]: string },
  read locks: { string },
  read onKey: board.OnKey,
  read drawKey: board.DrawKey,
}

type Board = board.Board
type RenderedKey = board.RenderedKey
type Pointer = board.Pointer

-- Keyboard options override provider rows, layers, and style.
local function settingsFor(settings: Settings, options: keyboard.Options?): Settings
  if not options or (options.rows == nil and options.layers == nil and options.style == nil) then
    return settings
  end
  local resolved = plugin.options {
    name = 'keyboard',
    defaults = { rows = settings.rows, layers = settings.layers, style = settings.style },
    config = { rows = options.rows, layers = options.layers, style = options.style },
  }
  local merged: Settings = {
    rows = resolved.rows,
    layers = resolved.layers,
    style = resolved.style,
    modifierKeys = settings.modifierKeys,
    locks = settings.locks,
    onKey = settings.onKey,
    drawKey = settings.drawKey,
  }
  validation.settings(merged, 'keyboard')
  return merged
end

local function scaled(style: keyboard.Style, scale: number): keyboard.Style
  return table.freeze {
    keyUnit = style.keyUnit * scale,
    gap = style.gap * scale,
    margin = style.margin * scale,
    plateDepth = style.plateDepth * scale,
    legendDepth = style.legendDepth * scale,
    legendHeight = style.legendHeight * scale,
    plateColor = style.plateColor,
    keyColor = style.keyColor,
    heldColor = style.heldColor,
    hoverColor = style.hoverColor,
    legendColor = style.legendColor,
  }
end

local function extentOf(settings: Settings): (number, number)
  local width, height = layout.extentOf(settings.rows)
  for _, rows in settings.layers do
    local layerWidth, layerHeight = layout.extentOf(rows)
    width, height = math.max(width, layerWidth), math.max(height, layerHeight)
  end
  return width, height
end

local function create(
  settings: Settings,
  options: keyboard.Options?,
  focusService: focus.Service,
  dispose: () -> ()
): (Board, () -> ())
  local unitsWide, unitsHigh = extentOf(settings)
  local style = settings.style
  local target: keyboard.Target = options and options.target or function()
    return focusService:focused()
  end
  local locks: { [string]: boolean } = {}
  for _, name in ipairs(settings.locks) do
    locks[name] = true
  end
  local latched: { [string]: boolean } = {}
  local locked: { [string]: boolean } = {}
  local hovered: { [Pointer]: RenderedKey } = {}
  local state = {
    kind = nil,
    source = nil,
    dead = false,
    grabbable = true,
    pose = options and options.pose and lovr.math.newMat4(options.pose) or lovr.math.newMat4(),
    width = unitsWide * style.keyUnit,
    height = unitsHigh * style.keyUnit,
    visible = true,
    layer = 'base',
  }
  local heldSink: lunette.Sink? = nil
  local heldSeat: lunette.Seat? = nil
  local heldKey: number? = nil

  local function modifiers(): { string }
    local held: { string } = {}
    for _, name in ipairs(keyVocabulary.MODIFIER_ORDER) do
      if latched[name] or locked[name] then
        held[#held + 1] = name
      end
    end
    return held
  end

  local function releaseInput(): ()
    local sink, seat, code = heldSink, heldSeat, heldKey
    heldSink, heldSeat, heldKey = nil, nil, nil
    if sink and not sink.dead and (not seat or not seat.dead) then
      if code then
        sink:key(code, false, seat)
      end
      sink:modifiers({}, seat)
    end
  end

  local function useTarget(): (lunette.Seat?, lunette.Sink?)
    if state.dead then
      return nil, nil
    end
    local seat, sink = target()
    if not sink or sink.dead or (seat and seat.dead) then
      return nil, nil
    end
    if heldSink ~= sink or heldSeat ~= seat then
      releaseInput()
    end
    heldSink, heldSeat = sink, seat
    return seat, sink
  end

  local function stroke(sink: lunette.Sink, seat: lunette.Seat?, code: number, held: { string }): ()
    sink:modifiers(held, seat)
    heldKey = code
    sink:key(code, true, seat)
    sink:key(code, false, seat)
    heldKey = nil
  end

  local function legendSeat(): lunette.Seat?
    local seat = target()
    if seat and not seat.dead then
      return seat
    end
    for _, candidate in ipairs(lunette.seats()) do
      if not candidate.dead then
        return candidate
      end
    end
    return nil
  end

  local function rowsOf(layer: string): { keyboard.KeyRow }
    if layer == 'base' then
      return settings.rows
    end
    return settings.layers[layer]
  end

  local function keys(): { RenderedKey }
    local seat, held = legendSeat(), modifiers()
    return layout.keysOf(rowsOf(state.layer), {
      keyUnit = style.keyUnit,
      modifierKeys = settings.modifierKeys,
      legendFor = function(entry: keyboard.Key): string
        return layout.legendFor(entry, seat, held)
      end,
    })
  end

  local function raycast(
    _self: keyboard.Surface,
    origin: vector,
    direction: vector,
    backFace: boolean?
  ): (number?, number?, number?)
    if state.dead or not state.visible then
      return nil, nil, nil
    end
    return quad.hit({
      pose = state.pose,
      width = state.width,
      height = state.height,
      pixelWidth = state.width,
      pixelHeight = state.height,
      backFace = backFace,
    }, origin, direction)
  end

  local function sendLatched(seat: lunette.Seat?, sink: lunette.Sink?): ()
    if next(latched) then
      table.clear(latched)
      if sink and not sink.dead and (not seat or not seat.dead) then
        sink:modifiers(modifiers(), seat)
      end
    end
  end

  local function pressKey(_self: keyboard.Keyboard, code: number): boolean
    if state.dead then
      return false
    end
    local modifier = settings.modifierKeys[code]
    if modifier then
      local set = if locks[modifier] then locked else latched
      set[modifier] = not set[modifier] or nil
      return true
    end
    local seat, sink = useTarget()
    if not sink then
      return false
    end
    stroke(sink, seat, code, modifiers())
    sendLatched(seat, sink)
    return true
  end

  local function typeText(_self: keyboard.Keyboard, text: string): boolean
    local seat, sink = useTarget()
    if not sink then
      return false
    end
    if not seat then
      return sink:typeText(text)
    end
    local pending: { string } = {}
    local function flush(): ()
      if #pending > 0 then
        sink:typeText(table.concat(pending), seat)
        table.clear(pending)
      end
    end
    for character in text:gmatch(CHARACTER) do
      local binding = seat:strokeFor(character)
      if binding then
        flush()
        stroke(sink, seat, binding.keycode, binding.modifiers)
      else
        pending[#pending + 1] = character
      end
    end
    flush()
    sink:modifiers(modifiers(), seat)
    return true
  end

  local function chord(code: number, held: { string }): ()
    local seat, sink = useTarget()
    if sink then
      stroke(sink, seat, code, held)
      sink:modifiers(modifiers(), seat)
    end
  end

  local function setLayer(_self: Board, layer: string): ()
    if layer ~= 'base' and settings.layers[layer] == nil then
      error('keyboard: there is no layer named ' .. tostring(layer), 2)
    end
    if not state.dead and state.layer ~= layer then
      state.layer = layer
      table.clear(hovered)
    end
  end

  local function setVisible(_self: keyboard.Keyboard, visible: boolean): ()
    state.visible = visible
  end

  -- What a key does when nothing overrides it: the base of `onKey`.
  local function perform(self: Board, key: RenderedKey, _pointer: Pointer): ()
    local code, action = key.code, key.action
    if code then
      pressKey(self, code)
    elseif not action then
      return
    elseif action.kind == 'hide' then
      setVisible(self, false)
    elseif action.kind == 'layer' then
      setLayer(self, action.layer)
    elseif action.kind == 'text' then
      typeText(self, action.text)
    elseif action.kind == 'chord' then
      chord(action.code, action.modifiers)
    end
  end

  local function isHovered(key: RenderedKey): boolean
    for _, entry in hovered do
      if entry.source == key.source then
        return true
      end
    end
    return false
  end

  local function isHeld(key: RenderedKey, held: { string }): boolean
    local action = key.action
    if action and action.kind == 'layer' then
      return action.layer ~= 'base' and action.layer == state.layer
    end
    return key.modifier ~= nil and table.find(held, key.modifier) ~= nil
  end

  local release: () -> boolean
  local created: Board

  local methods = {
    setPose = function(_self: keyboard.Surface, pose: Mat4): ()
      if not state.dead then
        state.pose:set(pose)
      end
    end,
    -- Uniform scaling preserves key proportions.
    setSize = function(_self: keyboard.Surface, wanted: number?, _height: number?): ()
      if state.dead or not wanted or wanted <= 0 or state.width <= 0 then
        return
      end
      style = scaled(style, wanted / state.width)
      state.width, state.height = unitsWide * style.keyUnit, unitsHigh * style.keyUnit
    end,
    raycast = raycast,
    onHover = function(_self: keyboard.Surface, x: number?, y: number?, pointer: Pointer): ()
      if not state.dead and x and y then
        hovered[pointer] = layout.keyAt(keys(), x, y)
      end
    end,
    onLeave = function(_self: keyboard.Surface, pointer: Pointer): ()
      hovered[pointer] = nil
    end,
    onPress = function(_self: keyboard.Surface, x: number?, y: number?, pointer: Pointer): ()
      if state.dead or not x or not y then
        return
      end
      local key = layout.keyAt(keys(), x, y)
      if key then
        settings.onKey(created, key, pointer, perform)
      end
    end,
    setVisible = setVisible,
    modifiers = function(_self: keyboard.Keyboard): { string }
      return modifiers()
    end,
    pressKey = pressKey,
    typeText = typeText,
    setLayer = setLayer,
    keys = function(_self: Board): { RenderedKey }
      return keys()
    end,
    draw = function(self: keyboard.Keyboard, pass: Pass): ()
      if state.dead or not state.visible then
        return
      end
      local width, height = state.width, state.height
      drawing.plate(pass, state.pose, width, height, style)
      local held = modifiers()
      for _, key in ipairs(keys()) do
        settings.drawKey(pass, key, {
          keyboard = created,
          pose = drawing.keyPose(state.pose, key, width, height),
          style = style,
          held = isHeld(key, held),
          hovered = isHovered(key),
        }, drawing.key)
      end
    end,
    destroy = function(_self: keyboard.Keyboard): boolean
      if state.dead then
        return false
      end
      return release()
    end,
  }
  created = setmetatable(state, { __index = methods })
  local function releaseRaw(): ()
    if state.dead then
      return
    end
    state.dead = true
    table.clear(latched)
    table.clear(locked)
    table.clear(hovered)
    releaseInput()
  end
  -- Direct destruction reports release failures to its caller.
  function release(): boolean
    local ok, failure = pcall(releaseRaw)
    dispose()
    if not ok then
      error(failure, 0)
    end
    return true
  end
  return created, releaseRaw
end

local function build(context: plugin.Context, settings: Settings): keyboard.Service
  local focusService: focus.Service = context:require(focus.capability)
  return {
    new = function(_self: keyboard.Service, owner: keyboard.Owner, options: keyboard.Options?): keyboard.Keyboard
      local own = settingsFor(settings, options)
      local cleanupEffect: plugin.Effect? = nil
      local result, acquired = context:resource(owner, function(): (Board, () -> ())
        local created, releaseRaw = create(own, options, focusService, function(): ()
          local effect = cleanupEffect
          cleanupEffect = nil
          if effect then
            effect:dispose()
          end
        end)
        return created, function(): ()
          cleanupEffect = nil
          releaseRaw()
        end
      end)
      if not result.dead then
        cleanupEffect = acquired
      end
      return result
    end,
  }
end

return build

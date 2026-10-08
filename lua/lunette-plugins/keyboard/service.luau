-- Each owner offers and draws its own keyboards. Focus sources own routed input delivery.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local focus = require '@lunette-contracts/focus'
local keyboard = require '@lunette-contracts/keyboard'
local keyVocabulary = require '@lunette-contracts/keys'
local quad = require '@lunette-contracts/quad'
local vocabulary = require '@lunette-contracts/vocabulary'
local board = require '@lunette-plugins/keyboard/board'
local drawing = require '@lunette-plugins/keyboard/draw'
local passState = require '@lunette-plugins/pass-state'
local layout = require '@lunette-plugins/keyboard/layout'
local validation = require '@lunette-plugins/keyboard/validation'
local inspection = require '@lunette-contracts/inspection'
local protected = require '@lunette-plugins/protected'

local config = require '@lunette-plugins/keyboard/config'

export type Settings = config.Settings

type Board = board.Board
type RenderedKey = board.RenderedKey
type Pointer = board.Pointer

-- Keyboard options override provider rows, layers, and style.
local function settingsFor(settings: Settings, options: keyboard.Options?): Settings
  if not options or (options.rows == nil and options.layers == nil and options.style == nil) then
    return settings
  end
  local merged =
    config.resolve({ rows = options.rows, layers = options.layers, style = options.style }, settings, 'keyboard')
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
  source: focus.Source,
  notify: (keyboard.VisibilityChange) -> (),
  dispose: () -> ()
): (Board, () -> (), () -> ())
  local unitsWide, unitsHigh = extentOf(settings)
  local style = settings.style
  local locks: { [string]: boolean } = {}
  for index = 1, #settings.locks do
    local name = settings.locks[index]
    locks[name] = true
  end
  local latched: { [string]: boolean } = {}
  local locked: { [string]: boolean } = {}
  local hovered: { [Pointer]: RenderedKey } = {}
  local captures: { [Pointer]: { [lunette.PointerButton]: boolean } } = {}
  local created: Board
  local pendingModifiers: { string }? = nil
  local visibilityRevision = 0
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

  local function modifiers(): { string }
    local held: { string } = {}
    for _, name in ipairs(keyVocabulary.MODIFIER_ORDER) do
      if latched[name] or locked[name] then
        held[#held + 1] = name
      end
    end
    return held
  end

  local function clearModifiers(): ()
    table.clear(latched)
    table.clear(locked)
    if pendingModifiers then
      table.clear(pendingModifiers)
    end
  end

  local function clearInput(): ()
    clearModifiers()
    source:reset()
  end

  local function cancelPointers(reason: vocabulary.CancelReason): { string }
    local active = captures
    captures = {}
    table.clear(hovered)
    local failures: { string } = {}
    for pointer in active do
      local ok, failure = pcall(function(): ()
        pointer:cancel(created, reason)
      end)
      if not ok then
        failures[#failures + 1] = tostring(failure)
      end
    end
    return failures
  end

  local function finish(failures: { string }): ()
    if #failures > 0 then
      error(table.concat(failures, '\n'), 0)
    end
  end

  local function rowsOf(layer: string): { read [number]: keyboard.KeyRow }
    if layer == 'base' then
      return settings.rows
    end
    return settings.layers[layer]
  end

  local function keys(): { RenderedKey }
    local seat, held = source:keymapSeat(), modifiers()
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

  local function project(_self: keyboard.Surface, origin: vector, direction: vector): (number?, number?, number?)
    if state.dead or not state.visible then
      return nil, nil, nil
    end
    return quad.project({
      pose = state.pose,
      width = state.width,
      height = state.height,
      pixelWidth = state.width,
      pixelHeight = state.height,
    }, origin, direction)
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
    local held = modifiers()
    table.clear(latched)
    pendingModifiers = held
    local ok, result = pcall(function(): focus.Result
      return source:key { code = code, modifiers = held, isRepeat = false }
    end)
    pendingModifiers = nil
    if not ok then
      error(result, 0)
    end
    return result.kind == 'consumed'
  end

  local function typeText(_self: keyboard.Keyboard, text: string): boolean
    if state.dead then
      return false
    end
    table.clear(latched)
    return source:text(text).kind == 'consumed'
  end

  local function chord(code: number, held: { read [number]: string }): ()
    if not state.dead then
      table.clear(latched)
      source:key { code = code, modifiers = held, isRepeat = false }
    end
  end

  local function setLayer(_self: Board, layer: string): ()
    if layer ~= 'base' and settings.layers[layer] == nil then
      error('keyboard: there is no layer named ' .. tostring(layer), 2)
    end
    if not state.dead and state.layer ~= layer then
      state.layer = layer
      finish(cancelPointers 'control-removed')
    end
  end

  local function visibility(visible: boolean, reason: 'show' | 'hide' | 'user-hide'): ()
    if state.dead or state.visible == visible then
      return
    end
    state.visible = visible
    visibilityRevision += 1
    local revision = visibilityRevision
    local failures: { string } = {}
    if not visible then
      clearModifiers()
      failures = cancelPointers 'hidden'
      if not state.dead and visibilityRevision == revision then
        local ok, failure = pcall(function(): ()
          source:reset()
        end)
        if not ok then
          failures[#failures + 1] = tostring(failure)
        end
      end
    end
    if not state.dead and visibilityRevision == revision then
      notify { visible = visible, reason = reason }
    end
    finish(failures)
  end

  local function setVisible(_self: keyboard.Keyboard, visible: boolean): ()
    visibility(visible, if visible then 'show' else 'hide')
  end

  -- What a key does when nothing overrides it: the base of `onKey`.
  local function perform(self: Board, key: RenderedKey, _pointer: Pointer): ()
    local code, action = key.code, key.action
    if code then
      pressKey(self, code)
    elseif not action then
      return
    elseif action.kind == 'hide' then
      visibility(false, 'user-hide')
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

  local function isHeld(key: RenderedKey, held: { read [number]: string }): boolean
    local action = key.action
    if action and action.kind == 'layer' then
      return action.layer ~= 'base' and action.layer == state.layer
    end
    if key.modifier ~= nil then
      for index = 1, #held do
        if held[index] == key.modifier then
          return true
        end
      end
    end
    return false
  end

  local function hover(x: number?, y: number?, pointer: Pointer): ()
    hovered[pointer] = if not state.dead and state.visible and x and y then layout.keyAt(keys(), x, y) else nil
  end

  local function activate(x: number?, y: number?, pointer: Pointer): ()
    if state.dead or not state.visible or not x or not y then
      return
    end
    local key = layout.keyAt(keys(), x, y)
    if key then
      settings.onKey(created, key, pointer, perform)
    end
  end

  local function onPointer(_self: keyboard.Surface, event: vocabulary.PointerEvent): ()
    local pointer = event.pointer
    if event.kind == 'cancel' or event.kind == 'release' then
      local buttons, button = captures[pointer], event.button
      if buttons and button then
        buttons[button] = nil
        if next(buttons) == nil then
          captures[pointer] = nil
        end
      end
      if event.kind == 'cancel' then
        hovered[pointer] = nil
      end
    elseif event.kind == 'leave' then
      hovered[pointer] = nil
    elseif event.kind == 'enter' or event.kind == 'move' then
      hover(if event.inside then event.x else nil, if event.inside then event.y else nil, pointer)
    elseif event.kind == 'press' and not state.dead and state.visible then
      if event.captured then
        local buttons = captures[pointer] or {}
        captures[pointer] = buttons
        buttons[event.button] = true
      end
      if event.button == 'left' and event.inside then
        activate(event.x, event.y, pointer)
      end
    end
  end

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
      if wanted == state.width then
        return
      end
      style = scaled(style, wanted / state.width)
      state.width, state.height = unitsWide * style.keyUnit, unitsHigh * style.keyUnit
      finish(cancelPointers 'control-removed')
    end,
    raycast = raycast,
    project = project,
    onPointer = onPointer,
    onHover = function(_self: keyboard.Surface, x: number?, y: number?, pointer: Pointer): ()
      hover(x, y, pointer)
    end,
    onLeave = function(_self: keyboard.Surface, pointer: Pointer): ()
      hovered[pointer] = nil
    end,
    onPress = function(_self: keyboard.Surface, x: number?, y: number?, pointer: Pointer): ()
      activate(x, y, pointer)
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
      passState.withRestore(pass, function()
        pass:setShader()
        pass:setMaterial(nil)
        pass:setFont(lovr.graphics.getDefaultFont())
        pass:setCullMode 'none'
        local width, height = state.width, state.height
        drawing.plate(pass, state.pose, width, height, style)
        local held = modifiers()
        for _, key in ipairs(keys()) do
          passState.withRestore(pass, function()
            settings.drawKey(pass, key, {
              keyboard = created,
              pose = drawing.keyPose(state.pose, key, width, height),
              style = style,
              held = isHeld(key, held),
              hovered = isHovered(key),
            }, drawing.key)
          end)
        end
      end)
    end,
    destroy = function(_self: keyboard.Keyboard): boolean
      if state.dead then
        return false
      end
      dispose()
      return true
    end,
  }
  created = setmetatable(state, { __index = methods })
  local function destroyState(): ()
    state.dead = true
    state.visible = false
    visibilityRevision += 1
    clearModifiers()
    pendingModifiers = nil
    finish(cancelPointers 'control-removed')
  end
  return created, destroyState, clearInput
end

local function build(context: plugin.Context, settings: Settings): keyboard.Service
  local focusService: focus.Service = context:require(focus.capability)
  local boards: { [Board]: keyboard.Owner } = {}
  return {
    inspect = function(_self: keyboard.Service): inspection.Snapshot
      local result: { inspection.Registration } = {}
      for target, owner in pairs(boards) do
        result[#result + 1] = inspection.registration(
          'keyboard',
          'keyboard.new',
          owner,
          nil,
          context:owns(owner) and not target.dead,
          { width = target.width, height = target.height, visible = target.visible, layer = target.layer }
        )
      end
      return inspection.snapshot(result, nil, { 'keyboard targets and legends require callbacks' })
    end,
    new = function(_self: keyboard.Service, owner: keyboard.Owner, options: keyboard.Options?): keyboard.Keyboard
      local own = settingsFor(settings, options)
      local callback = options and options.onVisibilityChanged
      if callback ~= nil and type(callback) ~= 'function' then
        error('keyboard: onVisibilityChanged is a function', 2)
      end
      local label = 'keyboard visibility (' .. plugin.ownerLabel(owner) .. ')'
      local function notify(change: keyboard.VisibilityChange): ()
        local run = callback
        if change.reason == 'destroy' then
          callback = nil
        end
        if run then
          protected.call(label, function(): ()
            run(change)
          end)
        end
      end
      local cleanupEffect: plugin.Effect? = nil
      local result, acquired = context:resource(owner, function(): (Board, () -> ())
        local source = focusService:newSource(context, { mode = 'virtual', nativeTarget = options and options.target })
        local changed: plugin.Effect? = nil
        local made: Board? = nil
        local destroyBoard: (() -> ())? = nil
        local ok, failure = pcall(function(): ()
          local created, destroyState, clearInput = create(own, options, source, notify, function(): ()
            local effect = cleanupEffect
            cleanupEffect = nil
            if effect then
              effect:dispose()
            end
          end)
          made, destroyBoard = created, destroyState
          changed = focusService:onChanged(context, {
            run = function(_change: focus.Change): ()
              if not created.dead then
                clearInput()
              end
            end,
          })
          boards[created] = owner
        end)
        if not ok then
          callback = nil
          if destroyBoard then
            destroyBoard()
          end
          local effect = changed
          changed = nil
          if effect then
            protected.call(label .. ': partial route listener cleanup', function(): ()
              effect:dispose()
            end)
          end
          protected.call(label .. ': partial source cleanup', function(): ()
            source:destroy()
          end)
          error(failure, 0)
        end
        local created, destroyState = made :: Board, destroyBoard :: () -> ()
        return created,
          function(): ()
            if created.dead then
              return
            end
            boards[created] = nil
            cleanupEffect = nil
            local effect = changed
            changed = nil
            local failures: { string } = {}
            local ended, endFailure = pcall(destroyState)
            if not ended then
              failures[#failures + 1] = tostring(endFailure)
            end
            if effect then
              local cleaned, failure = pcall(function(): ()
                effect:dispose()
              end)
              if not cleaned then
                failures[#failures + 1] = tostring(failure)
              end
            end
            local cleaned, failure = pcall(function(): ()
              source:destroy()
            end)
            if not cleaned then
              failures[#failures + 1] = tostring(failure)
            end
            notify { visible = false, reason = 'destroy' }
            if #failures > 0 then
              error(table.concat(failures, '\n'), 0)
            end
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

-- A board owns routed input, scaled appearance, and its active font lease.
local lunette = require '@lunette'
local focus = require '@lunette-contracts/focus'
local keyboard = require '@lunette-contracts/keyboard'
local keyVocabulary = require '@lunette-contracts/keys'
local quad = require '@lunette-contracts/quad'
local vocabulary = require '@lunette-contracts/vocabulary'
local theme = require '@lunette-contracts/theme'
local appearance = require './appearance'
local board = require './board'
local drawing = require './draw'
local passState = require '@lunette-plugins/pass-state'
local layout = require './layout'
local config = require './config'

local function extentOf(settings: config.Settings): (number, number)
  local width, height = layout.extentOf(settings.rows)
  for _, rows in settings.layers do
    local layerWidth, layerHeight = layout.extentOf(rows)
    width, height = math.max(width, layerWidth), math.max(height, layerHeight)
  end
  return width, height
end

local function prepare(nominal: keyboard.StyleOptions, lease: theme.FontLease, scale: number): keyboard.Style
  local prepared, style = pcall(appearance.scaled, nominal, lease.font, scale)
  if not prepared then
    local released, failure = pcall(function(): ()
      lease:dispose()
    end)
    if not released then
      error(tostring(style) .. '; keyboard font cleanup: ' .. tostring(failure), 0)
    end
    error(style, 0)
  end
  return style
end

local function construct(
  settings: config.Settings,
  options: keyboard.Options?,
  source: focus.Source,
  themeService: theme.Service,
  owner: keyboard.Owner,
  active: () -> boolean,
  notify: (keyboard.VisibilityChange) -> (),
  dispose: () -> (),
  acquired: (theme.FontLease) -> ()
): (board.Board, () -> (), () -> (), () -> ())
  local unitsWide, unitsHigh = extentOf(settings)
  local providerStyle = appearance.project(settings.style)
  local objectStyle = appearance.options.parse(options and options.style or {}, 'keyboard style')
  local pose = options and options.pose and lovr.math.newMat4(options.pose) or lovr.math.newMat4()
  local snapshot = themeService:current()
  local nominal = appearance.resolve(snapshot.theme, providerStyle, objectStyle)
  local lease = themeService:acquireFont(owner, nominal.font)
  acquired(lease)
  local scale = 1
  local style = appearance.scaled(nominal, lease.font, scale)
  local appliedRevision, geometryRevision = snapshot.revision, 0
  local refreshing = false
  local locks: { [string]: boolean } = {}
  for index = 1, #settings.locks do
    locks[settings.locks[index]] = true
  end
  local latched: { [string]: boolean } = {}
  local locked: { [string]: boolean } = {}
  local hovered: { [board.Pointer]: board.RenderedKey } = {}
  local captures: { [board.Pointer]: { [lunette.PointerButton]: boolean } } = {}
  local created: board.Board
  local pendingModifiers: { string }? = nil
  local visibilityRevision = 0
  local state = {
    kind = nil,
    source = nil,
    dead = false,
    grabbable = true,
    pose = pose,
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

  local function refresh(): ()
    if state.dead or refreshing or not active() then
      return
    end
    local latest = themeService:current()
    if latest.revision == appliedRevision then
      return
    end
    local nextNominal = appearance.resolve(latest.theme, providerStyle, objectStyle)
    local nextLease = themeService:acquireFont(owner, nextNominal.font)
    local nextStyle = prepare(nextNominal, nextLease, scale)
    local width, height = unitsWide * nextStyle.keyUnit, unitsHigh * nextStyle.keyUnit
    local geometryChanged = appearance.geometryChanged(style, nextStyle)
    local oldLease = lease
    nominal, lease, style, appliedRevision = nextNominal, nextLease, nextStyle, latest.revision
    state.width, state.height = width, height
    local failures: { string } = {}
    if geometryChanged then
      geometryRevision += 1
      refreshing = true
      failures = cancelPointers 'control-removed'
      refreshing = false
    end
    local released, failure = pcall(function(): ()
      oldLease:dispose()
    end)
    if not released then
      failures[#failures + 1] = tostring(failure)
    end
    finish(failures)
  end

  local function rowsOf(layer: string): { read [number]: keyboard.KeyRow }
    return if layer == 'base' then settings.rows else settings.layers[layer]
  end

  local function keys(): { board.RenderedKey }
    refresh()
    if state.dead or not active() then
      return {}
    end
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
    refresh()
    if state.dead or not state.visible or not active() then
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
    refresh()
    if state.dead or not state.visible or not active() then
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
    refresh()
    if state.dead or not active() then
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
    refresh()
    if state.dead or not active() then
      return false
    end
    table.clear(latched)
    return source:text(text).kind == 'consumed'
  end

  local function chord(code: number, held: { read [number]: string }): ()
    refresh()
    if not state.dead and active() then
      table.clear(latched)
      source:key { code = code, modifiers = held, isRepeat = false }
    end
  end

  local function setLayer(_self: board.Board, layer: string): ()
    if layer ~= 'base' and settings.layers[layer] == nil then
      error('keyboard: there is no layer named ' .. tostring(layer), 2)
    end
    if not state.dead and state.layer ~= layer then
      state.layer = layer
      geometryRevision += 1
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
  local function perform(self: board.Board, key: board.RenderedKey, _pointer: board.Pointer): ()
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

  local function isHovered(key: board.RenderedKey): boolean
    for _, entry in hovered do
      if entry.source == key.source then
        return true
      end
    end
    return false
  end

  local function isHeld(key: board.RenderedKey, held: { read [number]: string }): boolean
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

  local function hover(x: number?, y: number?, pointer: board.Pointer): ()
    local revision = geometryRevision
    refresh()
    hovered[pointer] = if revision == geometryRevision
        and not state.dead
        and active()
        and state.visible
        and x
        and y
      then layout.keyAt(keys(), x, y)
      else nil
  end

  local function activate(x: number?, y: number?, pointer: board.Pointer): ()
    local revision = geometryRevision
    refresh()
    if revision ~= geometryRevision or state.dead or not active() or not state.visible or not x or not y then
      return
    end
    local key = layout.keyAt(keys(), x, y)
    if key then
      settings.onKey(
        created,
        key,
        pointer,
        function(target: board.Board, entry: board.RenderedKey, input: board.Pointer): ()
          refresh()
          if not state.dead and active() and state.visible and geometryRevision == revision then
            perform(target, entry, input)
          end
        end
      )
    end
  end

  local function onPointer(_self: keyboard.Surface, event: vocabulary.PointerEvent): ()
    if event.kind == 'press' and event.captured and not state.dead and active() and state.visible then
      local buttons = captures[event.pointer] or {}
      captures[event.pointer] = buttons
      buttons[event.button] = true
    end
    local revision = geometryRevision
    if event.kind ~= 'cancel' and event.kind ~= 'release' and event.kind ~= 'leave' then
      refresh()
      if revision ~= geometryRevision or not active() then
        return
      end
    end
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
      if event.button == 'left' and event.inside then
        activate(event.x, event.y, pointer)
      end
    end
  end

  local methods = {
    setPose = function(_self: keyboard.Surface, wanted: Mat4): ()
      if not state.dead then
        state.pose:set(wanted)
      end
    end,
    -- Uniform scaling preserves key proportions.
    setSize = function(_self: keyboard.Surface, wanted: number?, _height: number?): ()
      refresh()
      if
        state.dead
        or not active()
        or not wanted
        or wanted ~= wanted
        or wanted <= 0
        or wanted >= math.huge
        or state.width <= 0
      then
        return
      end
      if wanted == state.width then
        return
      end
      local nextScale = scale * wanted / state.width
      local nextStyle = appearance.scaled(nominal, lease.font, nextScale)
      scale, style = nextScale, nextStyle
      geometryRevision += 1
      state.width, state.height = unitsWide * style.keyUnit, unitsHigh * style.keyUnit
      finish(cancelPointers 'control-removed')
    end,
    raycast = raycast,
    project = project,
    onPointer = onPointer,
    onHover = function(_self: keyboard.Surface, x: number?, y: number?, pointer: board.Pointer): ()
      hover(x, y, pointer)
    end,
    onLeave = function(_self: keyboard.Surface, pointer: board.Pointer): ()
      hovered[pointer] = nil
    end,
    onPress = function(_self: keyboard.Surface, x: number?, y: number?, pointer: board.Pointer): ()
      activate(x, y, pointer)
    end,
    setVisible = setVisible,
    modifiers = function(_self: keyboard.Keyboard): { string }
      return modifiers()
    end,
    pressKey = pressKey,
    typeText = typeText,
    setLayer = setLayer,
    keys = function(_self: board.Board): { board.RenderedKey }
      return keys()
    end,
    draw = function(_self: keyboard.Keyboard, pass: Pass): ()
      refresh()
      if state.dead or not active() or not state.visible then
        return
      end
      local revision, activeStyle, activeLease = geometryRevision, style, lease
      local width, height = state.width, state.height
      local rendered, held = keys(), modifiers()
      local function current(): boolean
        refresh()
        return not state.dead and active() and state.visible and geometryRevision == revision
      end
      activeLease:withFont(function(font: Font): ()
        passState.withRestore(pass, function(): ()
          pass:setShader()
          pass:setMaterial(nil)
          pass:setFont(font)
          pass:setCullMode 'none'
          if not current() then
            return
          end
          drawing.plate(pass, state.pose, width, height, activeStyle)
          for _, key in ipairs(rendered) do
            if not current() then
              break
            end
            passState.withRestore(pass, function(): ()
              pass:setFont(font)
              settings.drawKey(pass, key, {
                keyboard = created,
                pose = drawing.keyPose(state.pose, key, width, height),
                style = activeStyle,
                held = isHeld(key, held),
                hovered = isHovered(key),
              }, function(target: Pass, entry: board.RenderedKey, keyState: board.KeyState): ()
                if current() then
                  target:setFont(font)
                  drawing.key(target, entry, keyState)
                end
              end)
            end)
          end
        end)
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
    geometryRevision += 1
    local failures = cancelPointers 'control-removed'
    local released, failure = pcall(function(): ()
      lease:dispose()
    end)
    if not released then
      failures[#failures + 1] = tostring(failure)
    end
    finish(failures)
  end
  return created, destroyState, clearInput, refresh
end

local function create(
  settings: config.Settings,
  options: keyboard.Options?,
  source: focus.Source,
  themeService: theme.Service,
  owner: keyboard.Owner,
  active: () -> boolean,
  notify: (keyboard.VisibilityChange) -> (),
  dispose: () -> ()
): (board.Board, () -> (), () -> (), () -> ())
  local lease: theme.FontLease? = nil
  local ok, created, destroyState, clearInput, refresh = pcall(
    construct,
    settings,
    options,
    source,
    themeService,
    owner,
    active,
    notify,
    dispose,
    function(value: theme.FontLease): ()
      lease = value
    end
  )
  if not ok then
    local partialLease = lease
    if partialLease then
      local cleaned, failure = pcall(function(): ()
        partialLease:dispose()
      end)
      if not cleaned then
        error(tostring(created) .. '; keyboard font cleanup: ' .. tostring(failure), 0)
      end
    end
    error(created, 0)
  end
  return created, destroyState, clearInput, refresh
end

return create

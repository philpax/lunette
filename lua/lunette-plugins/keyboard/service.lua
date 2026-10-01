-- Keyboard resources and their registry belong to one provider activation.
--
-- A keyboard is a resource of the owner that asked for it. Its release runs as
-- an inverse on that owner, so a native release that fails is the owner's
-- failure rather than this provider's.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local interaction = require '@lunette-contracts/interaction'
local keyboard = require '@lunette-contracts/keyboard'
local quad = require '@lunette-contracts/quad'
local drawing = require '@lunette-plugins/keyboard/draw'
local keycodes = require '@mullion/keycodes'
local layout = require '@lunette-plugins/keyboard/layout'

local CHARACTER = '[%z\1-\127\194-\244][\128-\191]*'

-- The resolved options. Each activation receives its own frozen copy, so no
-- consumer can restyle another's keyboards. Resizing a keyboard makes it a new
-- style table.
export type Settings = {
  read style: keyboard.Style,
}

local function create(
  options: keyboard.Options?,
  defaults: keyboard.Style,
  interactionService: interaction.Service,
  remove: (keyboard.Keyboard) -> (),
  dispose: () -> ()
): (keyboard.Keyboard, () -> ())
  local rows: { keyboard.KeyRow } = {}
  if options and options.rows then
    rows = options.rows
  else
    for _, sourceRow in ipairs(keycodes.ROWS) do
      local row: keyboard.KeyRow = {}
      for _, entry in ipairs(sourceRow) do
        row[#row + 1] = { code = entry.code, label = entry.label, width = entry.width }
      end
      rows[#rows + 1] = row
    end
  end
  local style: keyboard.Style = options and options.style or defaults
  local width, height = layout.extentOf(rows, style)
  local target: keyboard.Target = options and options.target or function()
    return interactionService:focused()
  end
  local latched: { [string]: boolean } = {}
  local locked: { [string]: boolean } = {}
  local hovered: { [keyboard.HoverSource]: keyboard.RenderedKey? } = {}
  local state = {
    kind = nil,
    source = nil,
    dead = false,
    grabbable = true,
    pose = options and options.pose and lovr.math.newMat4(options.pose) or lovr.math.newMat4(),
    rows = rows,
    style = style,
    target = target,
    width = width,
    height = height,
    visible = true,
    latched = latched,
    locked = locked,
    hovered = hovered,
  }
  local heldSink: lunette.Sink? = nil
  local heldSeat: lunette.Seat? = nil
  local heldKey: number? = nil

  local function modifiers(): { string }
    local held: { string } = {}
    for _, name in ipairs(keycodes.MODIFIER_ORDER) do
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

  local function keys(): { keyboard.RenderedKey }
    local seat, held = legendSeat(), modifiers()
    return layout.keysOf(rows, state.style, function(entry: keyboard.Key): string
      return layout.legendFor(entry, seat, held)
    end)
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

  local function toggleModifier(_self: keyboard.Keyboard, name: string): ()
    if state.dead then
      return
    end
    local set = if keycodes.LOCKS[name] then locked else latched
    set[name] = not set[name] or nil
  end

  local function clearLatched(_self: keyboard.Keyboard, seat: lunette.Seat?, sink: lunette.Sink?): boolean
    if not next(latched) then
      return false
    end
    table.clear(latched)
    if sink and not sink.dead and (not seat or not seat.dead) then
      sink:modifiers(modifiers(), seat)
    end
    return true
  end

  local function pressKey(self: keyboard.Keyboard, code: number): boolean
    if state.dead then
      return false
    end
    local modifier = keycodes.MODIFIERS[code]
    if modifier then
      toggleModifier(self, modifier)
      return true
    end
    local seat, sink = useTarget()
    if not sink then
      return false
    end
    stroke(sink, seat, code, modifiers())
    clearLatched(self, seat, sink)
    return true
  end

  local function isHovered(_self: keyboard.Keyboard, code: number): boolean
    for _, entry in pairs(hovered) do
      if entry and entry.code == code then
        return true
      end
    end
    return false
  end

  local function isHeld(_self: keyboard.Keyboard, held: { string }, name: string): boolean
    return table.find(held, name) ~= nil
  end

  local release: () -> boolean

  local methods = {
    setPose = function(_self: keyboard.Surface, pose: Mat4): ()
      if not state.dead then
        state.pose:set(pose)
      end
    end,
    setSize = function(_self: keyboard.Surface, wanted: number?, _height: number?): ()
      if state.dead or not wanted or wanted <= 0 or state.width <= 0 then
        return
      end
      local scale = wanted / state.width
      local old = state.style
      state.style = {
        keyUnit = old.keyUnit * scale,
        gap = old.gap * scale,
        margin = old.margin * scale,
        plateDepth = old.plateDepth * scale,
        legendDepth = old.legendDepth * scale,
        legendHeight = old.legendHeight * scale,
        plateColor = old.plateColor,
        keyColor = old.keyColor,
        heldColor = old.heldColor,
        hoverColor = old.hoverColor,
        legendColor = old.legendColor,
      }
      state.width, state.height = layout.extentOf(rows, state.style)
    end,
    raycast = raycast,
    onHover = function(_self: keyboard.Surface, x: number?, y: number?, source: keyboard.HoverSource?): ()
      if not state.dead and x and y then
        hovered[source or 'default'] = layout.keyAt(keys(), x, y)
      end
    end,
    onLeave = function(_self: keyboard.Surface, source: keyboard.HoverSource?): ()
      hovered[source or 'default'] = nil
    end,
    onPress = function(_self: keyboard.Surface, _x: number?, _y: number?, _pointer: unknown?): () end,
    setHovered = function(_self: keyboard.Keyboard, entry: keyboard.RenderedKey?, source: keyboard.HoverSource?): ()
      if not state.dead then
        hovered[source or 'default'] = entry
      end
    end,
    isHovered = isHovered,
    setVisible = function(_self: keyboard.Keyboard, visible: boolean): ()
      state.visible = visible
    end,
    modifiers = function(_self: keyboard.Keyboard): { string }
      return modifiers()
    end,
    toggleModifier = toggleModifier,
    keys = function(_self: keyboard.Keyboard): { keyboard.RenderedKey }
      return keys()
    end,
    legendSeat = function(_self: keyboard.Keyboard): lunette.Seat?
      return legendSeat()
    end,
    legendFor = function(_self: keyboard.Keyboard, entry: keyboard.Key, seat: lunette.Seat?, held: { string }): string
      return layout.legendFor(entry, seat, held)
    end,
    hit = function(
      self: keyboard.Keyboard,
      origin: vector,
      direction: vector,
      backFace: boolean?
    ): (keyboard.RenderedKey?, number?)
      local x, y, distance = raycast(self, origin, direction, backFace)
      if not x or not y or not distance then
        return nil, nil
      end
      return layout.keyAt(keys(), x, y), distance
    end,
    pressKey = pressKey,
    typeText = function(_self: keyboard.Keyboard, text: string): boolean
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
    end,
    draw = function(self: keyboard.Keyboard, pass: Pass): ()
      if state.dead or not state.visible then
        return
      end
      local held = modifiers()
      drawing.keyboard(pass, state.pose, keys(), state.width, state.height, state.style, {
        held = function(entry: keyboard.RenderedKey): boolean
          return entry.modifier ~= nil and isHeld(self, held, entry.modifier)
        end,
        hovered = function(entry: keyboard.RenderedKey): boolean
          return isHovered(self, entry.code)
        end,
      })
    end,
    destroy = function(_self: keyboard.Keyboard): boolean
      if state.dead then
        return false
      end
      return release()
    end,
    isHeld = isHeld,
    clearLatched = clearLatched,
  }
  local created: keyboard.Keyboard = setmetatable(state, { __index = methods })
  local function releaseRaw(): ()
    if state.dead then
      return
    end
    state.dead = true
    remove(created)
    table.clear(latched)
    table.clear(locked)
    table.clear(hovered)
    releaseInput()
  end
  -- The release runs on the caller's stack, so its failure is the caller's;
  -- the owner's effect is then disposed with nothing left to do.
  function release(): boolean
    local ok, failure = pcall(releaseRaw)
    dispose()
    if not ok then
      error(failure, 0)
    end
    return true
  end
  methods.onPress = function(_self: keyboard.Surface, x: number?, y: number?, _pointer: unknown?): ()
    if state.dead or not x or not y then
      return
    end
    local entry = layout.keyAt(keys(), x, y)
    if entry then
      pressKey(created, entry.code)
    end
  end
  return created, releaseRaw
end

local function build(context: plugin.Context, settings: Settings): keyboard.Service
  local interactionService: interaction.Service = context:require(interaction.capability)
  local entries: { keyboard.Keyboard } = {}
  local defaults = settings.style
  local function remove(created: keyboard.Keyboard): ()
    local index = table.find(entries, created)
    if index then
      table.remove(entries, index)
    end
  end
  local service: keyboard.Service = {
    STYLE = defaults,
    new = function(_self: keyboard.Service, owner: keyboard.Owner, options: keyboard.Options?): keyboard.Keyboard
      context:checkOwner(owner)
      local result: keyboard.Keyboard? = nil
      local cleanupEffect: plugin.Effect? = nil
      local acquired = owner:effect(function(): () -> ()
        local created, releaseRaw = create(options, defaults, interactionService, remove, function(): ()
          local effect = cleanupEffect
          cleanupEffect = nil
          if effect then
            effect:dispose()
          end
        end)
        entries[#entries + 1] = created
        result = created
        return function(): ()
          cleanupEffect = nil
          releaseRaw()
        end
      end)
      assert(result, 'keyboard acquisition did not complete')
      if not result.dead then
        cleanupEffect = acquired
      end
      return result
    end,
    all = function(_self: keyboard.Service): { keyboard.Keyboard }
      return table.clone(entries)
    end,
    draw = function(_self: keyboard.Service, pass: Pass): ()
      for _, created in ipairs(entries) do
        created:draw(pass)
      end
    end,
    keyAt = function(
      _self: keyboard.Service,
      rendered: { keyboard.RenderedKey },
      x: number,
      y: number
    ): keyboard.RenderedKey?
      return layout.keyAt(rendered, x, y)
    end,
  }
  return service
end

return build

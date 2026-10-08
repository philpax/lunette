-- Panels offer one world surface and retain controls across draws and pointer frames.
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local surfaces = require '@lunette-contracts/surfaces'
local focus = require '@lunette-contracts/focus'
local surface = require '@lunette-contracts/surface'
local quad = require '@lunette-contracts/quad'
local records = require '@lunette-plugins/ui/panel-state'
local handles = require '@lunette-plugins/ui/control-handle'
local controlOwners = require '@lunette-plugins/ui/control-owners'
local controlOrder = require '@lunette-plugins/ui/control-order'
local validation = require '@lunette-plugins/ui/validation'
local input = require '@lunette-plugins/ui/input'
local geometry = require '@lunette-plugins/ui/geometry'
local theme = require '@lunette-plugins/ui/theme'
local globalTheme = require '@lunette-contracts/theme'
local appearance = require './appearance'
local panelDraw = require '@lunette-plugins/ui/panel-draw'
local draw = require './draw'
local button = require '@lunette-plugins/ui/button'
local textField = require '@lunette-plugins/ui/text-field'
local choice = require '@lunette-plugins/ui/choice'
local list = require '@lunette-plugins/ui/list'
local region = require '@lunette-plugins/ui/region'

local panel = {}

export type Services = {
  read focus: focus.Service,
  read surfaces: surfaces.Service,
  read owners: controlOwners.Registry,
  read theme: globalTheme.Service,
}

local function positive(value: number, name: string): ()
  assert(type(value) == 'number' and value > 0 and value < math.huge, 'ui: ' .. name .. ' is finite and positive')
end

local function cleanup(operations: { () -> () }): ()
  local failures: { string } = {}
  for _, operation in ipairs(operations) do
    local ok, failure = pcall(operation)
    if not ok then
      failures[#failures + 1] = tostring(failure)
    end
  end
  if #failures > 0 then
    error('ui: panel cleanup: ' .. table.concat(failures, '; '), 0)
  end
end

function panel.new(
  context: plugin.Context,
  owner: ui.Owner,
  options: ui.PanelOptions,
  services: Services,
  providerTheme: ui.ThemeOverrides,
  providerDraw: ui.DrawHook?,
  generation: ui.Generation,
  decorate: (string, surface.Surface, ui.TitlebarOptions) -> ui.Titlebar,
  disposed: () -> ()
): ui.Panel
  context:checkOwner(owner)
  options = validation.panel(options)
  assert(type(options.name) == 'string' and options.name ~= '', 'ui: panel name is a non-empty string')
  positive(options.width, 'width')
  positive(options.height, 'height')
  positive(options.logicalWidth, 'logicalWidth')
  positive(options.logicalHeight, 'logicalHeight')
  assert(options.visible == nil or type(options.visible) == 'boolean', 'ui: panel visible is a boolean')
  assert(options.grabbable == nil or type(options.grabbable) == 'boolean', 'ui: panel grabbable is a boolean')
  assert(options.draw == nil or type(options.draw) == 'function', 'ui: panel draw is a function')
  local givenPose = options.pose
  local pose = if givenPose then lovr.math.newMat4(givenPose) else lovr.math.newMat4()
  geometry.validatePose(pose)
  local snapshot = services.theme:current()
  local sx, sy = pose:getScale()
  local radiusX = snapshot.theme.radii.uiPanel * options.logicalWidth / (options.width * math.abs(sx))
  local radiusY = snapshot.theme.radii.uiPanel * options.logicalHeight / (options.height * math.abs(sy))
  local overrides = theme.copyOverrides(options.theme)
  local spec = theme.inherit(theme.inherit(theme.global(snapshot.theme, radiusX), providerTheme), overrides)
  local lease = services.theme:acquireFont(context, spec.font)
  local prepared, resolved = pcall(theme.materialize, spec, lease.font)
  if not prepared then
    local released, failure = pcall(lease.dispose, lease)
    error(tostring(resolved) .. (if released then '' else '; ' .. tostring(failure)), 0)
  end
  local state: records.Panel = {
    dead = false,
    visible = options.visible ~= false,
    cancelling = false,
    name = options.name,
    generation = generation,
    revision = 1,
    owner = owner,
    pose = pose,
    width = options.width,
    height = options.height,
    logicalWidth = options.logicalWidth,
    logicalHeight = options.logicalHeight,
    grabbable = options.grabbable ~= false,
    theme = resolved,
    providerTheme = providerTheme,
    overrides = overrides,
    spec = spec,
    lease = lease,
    measurements = draw.newCache(),
    themes = services.theme,
    themeRevision = snapshot.revision,
    radiusX = radiusX,
    radiusY = radiusY,
    refreshing = false,
    refresh = function(): () end,
    providerDraw = providerDraw,
    draw = options.draw,
    controls = {},
    owners = services.owners,
    nextOrder = 0,
    surface = nil,
    captures = {},
    pendingInput = {},
    hovered = {},
    pointerHover = {},
    context = context,
    focus = services.focus,
  }
  state.refresh = function(): ()
    appearance.refresh(state)
  end
  local release: plugin.Effect? = nil
  local offered: plugin.Effect? = nil
  local chrome: ui.Titlebar? = nil
  local function live(): boolean
    return not state.dead and context:active() and context:owns(owner)
  end
  local function cancel(reason: surface.CancelReason): ()
    local wasCancelling = state.cancelling
    state.cancelling = true
    local ok, failure = pcall(input.cancel, state, nil, reason)
    state.cancelling = wasCancelling
    if not ok then
      error(failure, 0)
    end
  end
  local function destroy(): boolean
    if state.dead then
      return false
    end
    state.dead, state.visible = true, false
    draw.clearCache(state.measurements)
    state.revision += 1
    local controls, oldOffer, oldChrome = state.controls, offered, chrome
    state.controls, offered, chrome = {}, nil, nil
    local operations: { () -> () } = {
      disposed,
      function(): ()
        if oldChrome then
          oldChrome:destroy()
        end
      end,
      function(): ()
        cancel 'surface-dead'
      end,
    }
    for _, record in ipairs(controls) do
      operations[#operations + 1] = function(): ()
        record.dispose()
      end
    end
    operations[#operations + 1] = function(): ()
      state.lease:dispose()
    end
    operations[#operations + 1] = function(): ()
      if oldOffer then
        oldOffer:dispose()
      end
    end
    cleanup(operations)
    return true
  end
  local function requireLive(): ()
    assert(live(), 'ui: panel is dead')
  end
  local function setPose(given: Mat4): ()
    if live() then
      geometry.validatePose(given)
      state.pose:set(given)
      state.revision += 1
      if chrome then
        chrome:sync()
      end
    end
  end
  local function setSize(width: number, height: number, logicalWidth: number?, logicalHeight: number?): ()
    if not live() then
      return
    end
    positive(width, 'width')
    positive(height, 'height')
    positive(logicalWidth or state.logicalWidth, 'logicalWidth')
    positive(logicalHeight or state.logicalHeight, 'logicalHeight')
    state.width, state.height = width, height
    state.logicalWidth, state.logicalHeight = logicalWidth or state.logicalWidth, logicalHeight or state.logicalHeight
    state.revision += 1
    cancel 'control-removed'
    if chrome then
      chrome:sync()
    end
  end
  local surfaceBase: surface.Surface = {
    attachFrame = nil,
    kind = nil,
    dead = false,
    grabbable = state.grabbable,
    grabTarget = if options.grabTarget
      then function(_self: surface.Surface): surface.Surface?
        return options.grabTarget
      end
      else nil,
    pose = state.pose,
    width = state.width,
    height = state.height,
    raycast = function(
      _self: surface.Surface,
      origin: vector,
      direction: vector,
      _captured: boolean?
    ): (number?, number?, number?)
      if not live() or not state.visible then
        return nil, nil, nil
      end
      state.refresh()
      return quad.hit({
        pose = state.pose,
        width = state.width,
        height = state.height,
        pixelWidth = state.logicalWidth,
        pixelHeight = state.logicalHeight,
      }, origin, direction)
    end,
    project = function(_self: surface.Surface, origin: vector, direction: vector): (number?, number?, number?)
      state.refresh()
      return quad.project({
        pose = state.pose,
        width = state.width,
        height = state.height,
        pixelWidth = state.logicalWidth,
        pixelHeight = state.logicalHeight,
      }, origin, direction)
    end,
    onPointer = function(_self: surface.Surface, event: surface.PointerEvent): ()
      input.event(state, event)
    end,
    setPose = function(_self: surface.Surface, given: Mat4): ()
      setPose(given)
    end,
    setSize = function(_self: surface.Surface, width: number?, height: number?): ()
      local nextWidth = width or state.width
      local nextHeight = height or (state.height * nextWidth / state.width)
      setSize(nextWidth, nextHeight, nil, nil)
    end,
  }
  local surfaceMethods: { read [string]: unknown } = {
    attachFrame = surfaceBase.attachFrame,
    kind = surfaceBase.kind,
    grabbable = surfaceBase.grabbable,
    grabTarget = surfaceBase.grabTarget,
    raycast = surfaceBase.raycast,
    project = surfaceBase.project,
    onPointer = surfaceBase.onPointer,
    setPose = surfaceBase.setPose,
    setSize = surfaceBase.setSize,
  }
  -- The checked surface supplies its methods; the metatable reads current geometry from the panel record.
  local offeredSurface: surface.Surface = table.freeze(setmetatable({}, {
    __index = function(_self: unknown, key: string): unknown
      if key == 'dead' then
        return state.dead or not state.visible
      elseif key == 'pose' then
        return state.pose
      elseif key == 'width' then
        return state.width
      elseif key == 'height' then
        return state.height
      end
      return surfaceMethods[key]
    end,
    __newindex = function(): ()
      error('ui: a panel surface is read-only', 2)
    end,
  })) :: surface.Surface
  state.surface = offeredSurface
  local base: ui.Panel = {
    dead = false,
    setPose = function(_self: ui.Panel, given: Mat4): ()
      setPose(given)
    end,
    setSize = function(
      _self: ui.Panel,
      width: number,
      height: number,
      logicalWidth: number?,
      logicalHeight: number?
    ): ()
      setSize(width, height, logicalWidth, logicalHeight)
    end,
    setVisible = function(_self: ui.Panel, visible: boolean): ()
      if not live() then
        return
      end
      assert(type(visible) == 'boolean', 'ui: visible is a boolean')
      if state.visible == visible then
        return
      end
      local targets: { [focus.TargetHandle]: boolean } = {}
      if not visible then
        for _, record in ipairs(state.controls) do
          local target = record.target
          if target then
            targets[target] = true
          end
        end
      end
      state.visible = visible
      state.revision += 1
      if chrome then
        chrome:sync()
      end
      if not visible then
        local focused: focus.TargetHandle? = nil
        cleanup {
          function(): ()
            local target = state.focus:focused()
            if target and targets[target] then
              focused = target
            end
          end,
          function(): ()
            cancel 'hidden'
          end,
          function(): ()
            local target = focused
            if target and not target.dead and state.focus:focused() == target then
              target:blur()
            end
          end,
        }
      end
    end,
    setTheme = function(_self: ui.Panel, overrides: ui.ThemeOverrides?): ()
      if not live() then
        return
      end
      local copied = theme.copyOverrides(overrides)
      local previous, previousLease = state.overrides, state.lease
      state.overrides = copied
      local ok, failure = pcall(appearance.refresh, state, true)
      if not ok then
        if state.lease == previousLease then
          state.overrides = previous
        end
        error(failure, 0)
      end
    end,
    describe = function(_self: ui.Panel): ui.Description
      state.refresh()
      local controls: { ui.ControlDescription } = {}
      for _, record in ipairs(controlOrder.ordered(state.controls)) do
        if not record.dead then
          controls[#controls + 1] = table.freeze {
            id = record.id,
            owner = record.identity,
            kind = record.kind,
            label = record.label,
            enabled = record.enabled,
            bounds = input.bounds(state, record),
            items = panelDraw.clippedItems(state, record),
          }
        end
      end
      return table.freeze {
        name = state.name,
        generation = state.generation,
        revision = state.revision,
        pose = table.freeze { state.pose:unpack(true) },
        width = state.width,
        height = state.height,
        logicalWidth = state.logicalWidth,
        logicalHeight = state.logicalHeight,
        visible = state.visible and not state.dead,
        controls = table.freeze(controls),
      }
    end,
    setTitlebar = function(_self: ui.Panel, given: ui.TitlebarOptions?): ()
      if not live() then
        return
      end
      if given then
        if chrome then
          chrome:update(given)
        else
          chrome = decorate(options.name .. '/titlebar', offeredSurface, given)
        end
      elseif chrome then
        local old = chrome
        chrome = nil
        old:destroy()
      end
    end,
    draw = function(_self: ui.Panel, pass: Pass): ()
      if chrome then
        chrome:draw(pass)
      end
      panelDraw.render(state, pass)
    end,
    destroy = function(_self: ui.Panel): boolean
      if state.dead then
        return false
      end
      local inverse = release
      release = nil
      cleanup {
        function(): ()
          destroy()
        end,
        function(): ()
          if inverse then
            inverse:dispose()
          end
        end,
      }
      return true
    end,
    button = function(_self: ui.Panel, controlOwner: ui.Owner, given: ui.ButtonOptions): ui.Button
      requireLive()
      given = validation.button(given)
      return handles.create(state, controlOwner, given, function(host)
        return button.new(given, host)
      end)
    end,
    textField = function(_self: ui.Panel, controlOwner: ui.Owner, given: ui.TextFieldOptions): ui.TextField
      requireLive()
      given = validation.textField(given)
      return handles.create(state, controlOwner, given, function(host)
        return textField.new(given, host)
      end) :: ui.TextField
    end,
    choice = function(_self: ui.Panel, controlOwner: ui.Owner, given: ui.ChoiceOptions): ui.Choice
      requireLive()
      given = validation.choice(given)
      return handles.create(state, controlOwner, given, function(host)
        return choice.new(given, host)
      end) :: ui.Choice
    end,
    list = function(_self: ui.Panel, controlOwner: ui.Owner, given: ui.ListOptions): ui.List
      requireLive()
      given = validation.list(given)
      return handles.create(state, controlOwner, given, function(host)
        return list.new(given, host)
      end) :: ui.List
    end,
    region = function(_self: ui.Panel, controlOwner: ui.Owner, given: ui.RegionOptions): ui.Region
      requireLive()
      given = validation.region(given)
      return handles.create(state, controlOwner, given, function(host)
        return region.new(given, host)
      end) :: ui.Region
    end,
  }
  local methods: { read [string]: unknown } = {
    setPose = base.setPose,
    setSize = base.setSize,
    setVisible = base.setVisible,
    setTheme = base.setTheme,
    setTitlebar = base.setTitlebar,
    describe = base.describe,
    draw = base.draw,
    destroy = base.destroy,
    button = base.button,
    textField = base.textField,
    choice = base.choice,
    list = base.list,
    region = base.region,
  }
  -- The checked panel supplies its methods; the metatable keeps dead read-only and current.
  local handle: ui.Panel = table.freeze(setmetatable({}, {
    __index = function(_self: unknown, key: string): unknown
      return if key == 'dead' then state.dead else methods[key]
    end,
    __newindex = function(): ()
      error('ui: a panel is read-only', 2)
    end,
  })) :: ui.Panel
  local ok, failure = pcall(function(): ()
    offered = services.surfaces:offer(context, {
      name = options.name,
      list = function(): { surface.Surface }
        return if live() and state.visible then { offeredSurface } else {}
      end,
    })
    if options.titlebar then
      chrome = decorate(options.name .. '/titlebar', offeredSurface, options.titlebar)
    end
    release = context:acquire(owner, function(): () -> ()
      return function(): ()
        release = nil
        destroy()
      end
    end)
  end)
  if not ok then
    destroy()
    error(failure, 0)
  end
  return handle
end

return panel

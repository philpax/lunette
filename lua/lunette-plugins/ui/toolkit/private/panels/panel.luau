-- Panels offer one world surface and retain controls across draws and pointer frames.
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local surfaces = require '@lunette-contracts/surfaces'
local focus = require '@lunette-contracts/focus'
local quad = require '@lunette-contracts/quad'
local records = require './panel-state'
local handles = require '../controls/control-handle'
local controlOwners = require '../controls/control-owners'
local validation = require '../validation'
local input = require '../controls/input'
local geometry = require '../rendering/geometry'
local theme = require '../rendering/theme'
local globalTheme = require '@lunette-contracts/theme'
local appearance = require './appearance'
local panelDraw = require './panel-draw'
local draw = require '../rendering/draw'
local cleanup = require '@lunette-plugins/lifecycle/cleanup'
local button = require '../controls/button'
local textField = require '../text/text-field'
local collection = require '../controls/collection'
local region = require '../controls/region'
local panelGeometry = require './panel-geometry'
local rounded = require '@lunette-plugins/graphics/rounded-geometry'
local drawing = require '@lunette-plugins/graphics/rounded-drawing'
local vocabulary = require '@lunette-contracts/vocabulary'

local panel = {}

export type Services = {
  read focus: focus.Service,
  read surfaces: surfaces.Service,
  read owners: controlOwners.Registry,
  read theme: globalTheme.Service,
}
-- One provider activation shares these with every panel it creates.
export type Provider = {
  read context: plugin.Context,
  read services: Services,
  read theme: ui.ThemeOverrides,
  read newTitlebar: (ui.Owner, string, vocabulary.Surface, ui.TitlebarOptions, (() -> boolean)?) -> ui.Titlebar,
}

-- Options arrive validated by the service; the returned record is the provider's private view of the handle.
function panel.new(provider: Provider, owner: ui.Owner, options: ui.PanelOptions): (ui.Panel, records.Panel)
  local context, services = provider.context, provider.services
  local pose = if options.pose then lovr.math.newMat4(options.pose) else lovr.math.newMat4()
  local snapshot = services.theme:current()
  local overrides = options.theme
  local state: records.Panel = {
    dead = false,
    visible = options.visible ~= false,
    cancelling = false,
    name = options.name,
    revision = 1,
    owner = owner,
    pose = pose,
    width = options.width,
    height = options.height,
    logicalWidth = options.logicalWidth,
    logicalHeight = options.logicalHeight,
    grabbable = options.grabbable ~= false,
    theme = theme.materialize(theme.DEFAULT, services.theme:font()),
    providerTheme = provider.theme,
    overrides = overrides,
    spec = theme.DEFAULT,
    measurements = draw.newCache(),
    themes = services.theme,
    themeRevision = snapshot.revision,
    radiusX = 0,
    radiusY = 0,
    shape = nil,
    contour = nil,
    frame = nil,
    frameMeshes = drawing.newCache(),
    refresh = function(): () end,
    controls = {},
    owners = services.owners,
    nextOrder = 0,
    surface = nil,
    captures = {},
    hovered = {},
    pointerHover = {},
    context = context,
    focus = services.focus,
  }
  state.radiusX, state.radiusY = appearance.radii(snapshot, state)
  state.refresh = function(): ()
    appearance.refresh(state)
  end
  appearance.refresh(state, true)
  local release: plugin.Effect? = nil
  local offered: plugin.Effect? = nil
  local chrome: ui.Titlebar? = nil
  -- Handles are plain tables; this copies the record's current state into their public fields.
  local publish: () -> ()
  local function live(): boolean
    return not state.dead and context:active() and context:owns(owner)
  end
  local function destroy(): boolean
    if state.dead then
      return false
    end
    state.dead, state.visible = true, false
    state.revision += 1
    local controls, oldOffer, oldChrome, oldFrame = state.controls, offered, chrome, state.frame
    state.controls, offered, chrome = {}, nil, nil
    publish()
    local operations: { () -> () } = {
      function(): ()
        draw.clearCache(state.measurements)
      end,
      function(): ()
        drawing.clear(state.frameMeshes)
      end,
      function(): ()
        if oldFrame then
          oldFrame.dispose()
        end
      end,
      function(): ()
        if oldChrome then
          oldChrome:destroy()
        end
      end,
      function(): ()
        input.cancel(state, nil, 'surface-dead')
      end,
    }
    for _, record in ipairs(controls) do
      operations[#operations + 1] = function(): ()
        record.dispose()
      end
    end
    operations[#operations + 1] = function(): ()
      if oldOffer then
        oldOffer:dispose()
      end
    end
    cleanup.run('ui: panel cleanup', operations)
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
    geometry.positive(width, 'width')
    geometry.positive(height, 'height')
    geometry.positive(logicalWidth or state.logicalWidth, 'logicalWidth')
    geometry.positive(logicalHeight or state.logicalHeight, 'logicalHeight')
    state.width, state.height = width, height
    state.logicalWidth, state.logicalHeight = logicalWidth or state.logicalWidth, logicalHeight or state.logicalHeight
    state.revision += 1
    publish()
    input.cancel(state, nil, 'control-removed')
    if chrome then
      chrome:sync()
    end
  end
  local offeredSurface: vocabulary.Surface = {
    attachFrame = function(
      _self: vocabulary.Surface,
      frameOwner: plugin.Owner,
      style: vocabulary.FrameStyle
    ): vocabulary.FrameAttachment
      return panelGeometry.attach(state, frameOwner, style, function(geometryChanged: boolean): ()
        state.revision += 1
        if geometryChanged and not state.dead then
          input.cancel(state, nil, 'control-removed')
        end
      end)
    end,
    kind = nil,
    dead = false,
    grabbable = state.grabbable,
    grabTarget = if options.grabTarget
      then function(_self: vocabulary.Surface): vocabulary.Surface?
        return options.grabTarget
      end
      else nil,
    pose = state.pose,
    width = state.width,
    height = state.height,
    raycast = function(
      _self: vocabulary.Surface,
      origin: vector,
      direction: vector,
      backFace: boolean?
    ): (number?, number?, number?)
      if not live() or not state.visible then
        return nil, nil, nil
      end
      state.refresh()
      local x, y, distance = quad.hit({
        pose = state.pose,
        width = state.width,
        height = state.height,
        pixelWidth = state.logicalWidth,
        pixelHeight = state.logicalHeight,
        backFace = backFace,
      }, origin, direction)
      if x and y and rounded.contains(panelGeometry.prepare(state).polygon, x, y) then
        return x, y, distance
      end
      return nil, nil, nil
    end,
    project = function(_self: vocabulary.Surface, origin: vector, direction: vector): (number?, number?, number?)
      state.refresh()
      return quad.project({
        pose = state.pose,
        width = state.width,
        height = state.height,
        pixelWidth = state.logicalWidth,
        pixelHeight = state.logicalHeight,
      }, origin, direction)
    end,
    onPointer = function(_self: vocabulary.Surface, event: vocabulary.PointerEvent): ()
      input.event(state, event)
    end,
    setPose = function(_self: vocabulary.Surface, given: Mat4): ()
      setPose(given)
    end,
    setSize = function(_self: vocabulary.Surface, width: number?, height: number?): ()
      local nextWidth = width or state.width
      local nextHeight = height or (state.height * nextWidth / state.width)
      setSize(nextWidth, nextHeight, nil, nil)
    end,
  }
  state.surface = offeredSurface
  local handle: ui.Panel = {
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
      publish()
      if chrome then
        chrome:sync()
      end
      if not visible then
        local current = state.focus:focused()
        local focused = if current and targets[current] then current else nil
        cleanup.run('ui: panel cleanup', {
          function(): ()
            input.cancel(state, nil, 'hidden')
          end,
          function(): ()
            if focused and not focused.dead and state.focus:focused() == focused then
              focused:blur()
            end
          end,
        })
      end
    end,
    setTheme = function(_self: ui.Panel, overrides: ui.ThemeOverrides?): ()
      if not live() then
        return
      end
      local copied = theme.copyOverrides(overrides)
      local previous, previousTheme = state.overrides, state.theme
      state.overrides = copied
      local ok, failure = pcall(appearance.refresh, state, true)
      if not ok then
        if state.theme == previousTheme then
          state.overrides = previous
        end
        error(failure, 0)
      end
    end,
    setTitlebar = function(_self: ui.Panel, given: ui.TitlebarOptions?): ()
      if not live() then
        return
      end
      if given then
        if chrome then
          chrome:update(given)
        else
          chrome = provider.newTitlebar(owner, options.name .. '/titlebar', offeredSurface, given)
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
      cleanup.run('ui: panel cleanup', {
        function(): ()
          destroy()
        end,
        function(): ()
          if inverse then
            inverse:dispose()
          end
        end,
      })
      return true
    end,
    button = function(_self: ui.Panel, given: ui.ButtonOptions): ui.Button
      requireLive()
      given = validation.button(given)
      return handles.create(state, given.owner or owner, 'button', given, function(host: records.Host): records.Widget
        return button.new(given, host)
      end)
    end,
    textField = function(_self: ui.Panel, given: ui.TextFieldOptions): ui.TextField
      requireLive()
      given = validation.textField(given)
      return handles.create(
        state,
        given.owner or owner,
        'text-field',
        given,
        function(host: records.Host): records.Widget
          return textField.new(given, host)
        end
      ) :: ui.TextField
    end,
    choice = function(_self: ui.Panel, given: ui.ChoiceOptions): ui.Choice
      requireLive()
      given = validation.choice(given)
      return handles.create(
          state,
          given.owner or owner,
          'choice',
          given,
          function(host: records.Host): records.Widget
            return collection.widget('choice', given, host)
          end
        ) :: ui.Choice
    end,
    list = function(_self: ui.Panel, given: ui.ListOptions): ui.List
      requireLive()
      given = validation.list(given)
      return handles.create(
          state,
          given.owner or owner,
          'list',
          given,
          function(host: records.Host): records.Widget
            return collection.widget('list', given, host)
          end
        ) :: ui.List
    end,
    region = function(_self: ui.Panel, given: ui.RegionOptions): ui.Region
      requireLive()
      given = validation.region(given)
      return handles.create(
          state,
          given.owner or owner,
          'region',
          given,
          function(host: records.Host): records.Widget
            return region.new(given, host)
          end
        ) :: ui.Region
    end,
  }
  local surfaceFields = (offeredSurface :: unknown) :: { dead: boolean, width: number, height: number }
  local handleFields = (handle :: unknown) :: { dead: boolean }
  publish = function(): ()
    surfaceFields.dead = state.dead or not state.visible
    surfaceFields.width, surfaceFields.height = state.width, state.height
    handleFields.dead = state.dead
  end
  publish()
  local ok, failure = pcall(function(): ()
    offered = services.surfaces:offer(context, {
      name = options.name,
      list = function(): { vocabulary.Surface }
        return if live() and state.visible then { offeredSurface } else {}
      end,
    })
    if options.titlebar then
      chrome = provider.newTitlebar(owner, options.name .. '/titlebar', offeredSurface, options.titlebar)
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
  return handle, state
end

return panel

-- Public quad surfaces route gestures and describe the same logical panel geometry they draw.

local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local pointerRouting = require './pointer-routing'
local protected = require '@lunette-plugins/protected'
local appearance = require './appearance'
local geometry = require './geometry'
local items = require './items'
local controls = require './controls'
local surfaceGeometry = require './surface-geometry'
local drawing = require '@lunette-plugins/theme/drawing'

local panels = {}

local function stableRadius(value, previous)
  -- Float matrix decomposition perturbs scale during rigid rotation.
  return if math.abs(value - previous) <= 1e-6 * math.max(value, previous) then previous else value
end

function panels.new(provider, owner, options)
  for _, value in { options.width, options.height, options.logicalWidth, options.logicalHeight } do
    assert(geometry.finite(value) and value > 0, 'ui substitute: panel dimensions are finite and positive')
  end
  assert(type(options.name) == 'string' and options.name ~= '', 'ui substitute: panel name is nonempty')
  local panel = {
    dead = false,
    provider = provider,
    owner = owner,
    name = options.name,
    controls = {},
    revision = 1,
    visible = options.visible ~= false,
    overrides = appearance.copyOverrides(options.theme),
    drawHook = options.draw,
    gestures = {},
    meshes = drawing.newCache(),
    frameMeshes = drawing.newCache(),
  }
  panel.surface = {
    dead = false,
    kind = nil,
    grabbable = options.grabbable ~= false,
    grabTarget = if options.grabTarget
      then function()
        return options.grabTarget
      end
      else nil,
    pose = if options.pose then lovr.math.newMat4(options.pose) else lovr.math.newMat4(),
    width = options.width,
    height = options.height,
    pixelWidth = options.logicalWidth,
    pixelHeight = options.logicalHeight,
  }
  local handle = { dead = false }
  local chrome: ui.Titlebar? = nil
  local refreshing = false
  function panel.live()
    return not panel.dead and provider.context:owns(owner)
  end
  function panel.theme()
    panel.refresh()
    return panel.resolved
  end
  function panel.refresh()
    if refreshing or panel.dead or not provider.context:active() or not owner:active() then
      return
    end
    refreshing = true
    local completed, failure = pcall(function()
      provider.refreshBase()
      local base = table.clone(provider.base)
      local sx, sy = panel.surface.pose:getScale()
      local revision = provider.theme:current().revision
      if provider.overrides.panelRadius == nil then
        local radiusX = provider.radius * panel.surface.pixelWidth / (panel.surface.width * math.abs(sx))
        base.panelRadius = if revision == panel.themeRevision
          then stableRadius(radiusX, panel.resolved.panelRadius)
          else radiusX
      end
      local changed = appearance.resolve(panel, base, panel.overrides)
      local explicit = (panel.overrides and panel.overrides.panelRadius) or provider.overrides.panelRadius
      local radiusY = if explicit ~= nil
        then explicit
        else provider.radius * panel.surface.pixelHeight / (panel.surface.height * math.abs(sy))
      if revision == panel.themeRevision then
        radiusY = stableRadius(radiusY, panel.radiusY)
      end
      changed = changed or (panel.radiusY ~= nil and panel.radiusY ~= radiusY)
      panel.radiusY, panel.themeRevision = radiusY, revision
      for _, control in table.clone(panel.controls) do
        if control.live() then
          changed = control.refresh() or changed
        end
      end
      if changed then
        panel.shape = nil
        drawing.clear(panel.meshes)
        drawing.clear(panel.frameMeshes)
        for _, control in panel.controls do
          drawing.clear(control.meshes)
        end
        panel.revision += 1
        panel.cancel(nil, 'control-removed')
      end
    end)
    refreshing = false
    if not completed then
      error(failure, 0)
    end
  end
  provider.refreshBase()
  local initialBase = table.clone(provider.base)
  local initialScaleX, initialScaleY = panel.surface.pose:getScale()
  if provider.overrides.panelRadius == nil then
    initialBase.panelRadius = provider.radius
      * panel.surface.pixelWidth
      / (panel.surface.width * math.abs(initialScaleX))
  end
  appearance.resolve(panel, initialBase, panel.overrides)
  local explicit = (panel.overrides and panel.overrides.panelRadius) or provider.overrides.panelRadius
  panel.radiusY = if explicit ~= nil
    then explicit
    else provider.radius * panel.surface.pixelHeight / (panel.surface.height * math.abs(initialScaleY))
  panel.themeRevision = provider.theme:current().revision
  function panel.bounds()
    return { x = 0, y = 0, width = panel.surface.pixelWidth, height = panel.surface.pixelHeight }
  end
  function panel.clip()
    return surfaceGeometry.shape(panel).clip
  end
  function panel.surface.attachFrame(_, frameOwner, style)
    return surfaceGeometry.attach(panel, frameOwner, style)
  end
  pointerRouting.install(panel)
  function handle.setPose(_: ui.Panel, pose: Mat4)
    if not panel.live() then
      return
    end
    panel.surface.pose:set(pose)
    panel.revision += 1
    for _, gestures in panel.gestures do
      for _, gesture in gestures do
        gesture.revision = panel.revision
      end
    end
    if chrome then
      chrome:sync()
    end
  end
  function handle.setSize(_: ui.Panel, width: number, height: number, logicalWidth: number?, logicalHeight: number?)
    if not panel.live() then
      return
    end
    for _, value in
      { width, height, logicalWidth or panel.surface.pixelWidth, logicalHeight or panel.surface.pixelHeight }
    do
      assert(geometry.finite(value) and value > 0, 'ui substitute: panel dimensions are finite and positive')
    end
    panel.cancel(nil, 'control-removed')
    panel.surface.width, panel.surface.height = width, height
    panel.surface.pixelWidth, panel.surface.pixelHeight =
      logicalWidth or panel.surface.pixelWidth, logicalHeight or panel.surface.pixelHeight
    panel.shape = nil
    drawing.clear(panel.meshes)
    drawing.clear(panel.frameMeshes)
    for _, control in panel.controls do
      drawing.clear(control.meshes)
    end
    panel.refresh()
    panel.revision += 1
    if chrome then
      chrome:sync()
    end
  end
  function panel.surface.setPose(_, pose)
    handle:setPose(pose)
  end
  function panel.surface.setSize(_, width, height)
    local nextWidth = width or panel.surface.width
    handle:setSize(nextWidth, height or panel.surface.height * nextWidth / panel.surface.width)
  end
  function handle.setVisible(_: ui.Panel, value: boolean)
    if not panel.live() or panel.visible == value then
      return
    end
    panel.visible = value
    panel.revision += 1
    if chrome then
      chrome:sync()
    end
    if not value then
      panel.cancel(nil, 'hidden')
      local ordered = table.clone(panel.controls)
      for index, control in ordered do
        if control.focused then
          table.remove(ordered, index)
          table.insert(ordered, 1, control)
          break
        end
      end
      for _, control in ordered do
        control.hovered = {}
        if control.target then
          control.target:blur()
        end
      end
    end
  end
  function handle.setTheme(_: ui.Panel, value: ui.ThemeOverrides?)
    if not panel.live() then
      return
    end
    local copied = appearance.copyOverrides(value)
    local previous = panel.overrides
    panel.overrides = copied
    local ok, failure = pcall(panel.refresh)
    if not ok then
      panel.overrides = previous
      error(failure, 0)
    end
  end
  function handle.describe(_: ui.Panel): ui.Description
    panel.refresh()
    local described = {}
    for _, control in panel.controls do
      if control.live() then
        described[#described + 1] = table.freeze {
          id = control.id,
          owner = control.identity,
          kind = control.kind,
          label = control.label,
          enabled = control.enabled,
          bounds = geometry.intersect(control.bounds, panel.clip()),
          items = appearance.snapshotItems(items.rows(control)),
        }
      end
    end
    return table.freeze {
      name = panel.name,
      generation = provider.generation,
      revision = panel.revision,
      pose = table.freeze { panel.surface.pose:unpack(true) },
      width = panel.surface.width,
      height = panel.surface.height,
      logicalWidth = panel.surface.pixelWidth,
      logicalHeight = panel.surface.pixelHeight,
      visible = panel.live() and panel.visible,
      controls = table.freeze(described),
    }
  end
  function handle.setTitlebar(_: ui.Panel, given: ui.TitlebarOptions?)
    if not panel.live() then
      return
    end
    if given then
      if chrome then
        chrome:update(given)
      else
        chrome = provider.decorate(owner, panel.name .. '/titlebar', panel.surface, given, function()
          return panel.live() and panel.visible
        end)
      end
    elseif chrome then
      local old = chrome
      chrome = nil
      old:destroy()
    end
  end
  function handle.draw(_: ui.Panel, pass: Pass)
    panel.refresh()
    if not panel.live() or not panel.visible then
      return
    end
    if chrome then
      chrome:draw(pass)
    end
    local function render()
      panel.refresh()
      local revision = panel.revision
      local themeRevision = provider.theme:current().revision
      local function current()
        return panel.live()
          and panel.visible
          and panel.revision == revision
          and provider.theme:current().revision == themeRevision
      end
      surfaceGeometry.outline(panel, pass)
      pass:transform(panel.surface.pose)
      pass:translate(-panel.surface.width / 2, panel.surface.height / 2, 0)
      pass:scale(panel.surface.width / panel.surface.pixelWidth, -panel.surface.height / panel.surface.pixelHeight, 1)
      local function visual(control)
        local box = if control then control.bounds else panel.bounds()
        local value, overflow = control and control.value, nil
        if control and (control.kind == 'choice' or control.kind == 'list') then
          local style = control.theme()
          local header = if control.kind == 'choice' then style.rowHeight + style.spacing else 0
          local content = math.max(0, #control.items * (style.rowHeight + style.spacing) - style.spacing)
          overflow = content > math.max(0, box.height - 2 * style.padding - header)
          if control.kind == 'choice' then
            for _, item in control.items do
              if item.id == control.chosen then
                value = item.label
              end
            end
          end
        end
        return {
          id = if control then control.id else panel.name,
          kind = if control then control.kind else 'panel',
          label = if control then control.label else panel.name,
          bounds = box,
          clip = if control then geometry.intersect(box, panel.clip()) else panel.bounds(),
          theme = if control then control.theme() else panel.theme(),
          enabled = not control or control.enabled,
          hovered = control ~= nil and next(control.hovered) ~= nil,
          pressed = control ~= nil and next(control.presses) ~= nil,
          focused = control ~= nil and control.focused == true,
          value = value,
          caret = control and control.caret,
          anchor = control and control.anchor,
          error = control and control.error,
          opened = control and control.opened,
          overflow = overflow,
          items = if control then items.rows(control) else {},
        }
      end
      local panelHooks = if provider.draw then { provider.draw } else {}
      if panel.drawHook then
        panelHooks[#panelHooks + 1] = panel.drawHook
      end
      local shape = surfaceGeometry.shape(panel)
      local backing = {
        bounds = shape.bounds,
        profile = shape.profile,
        border = panel.contour == nil and not (panel.frame and panel.frame.joined()),
      }
      panel.lease:withFont(function()
        appearance.paint(owner, pass, visual(nil), panelHooks, panel.meshes, backing, current)
      end)
      if not current() then
        return
      end
      local ordered = table.clone(panel.controls)
      table.sort(ordered, function(a, b)
        return a.z < b.z
      end)
      for _, control in ordered do
        if not current() then
          return
        end
        if control.live() and geometry.intersect(control.bounds, panel.clip()) then
          local hooks = table.clone(panelHooks)
          if control.drawHook then
            hooks[#hooks + 1] = control.drawHook
          end
          local controlShape
          if panel.contour then
            controlShape = { bounds = shape.bounds, profile = shape.profile, border = false }
          end
          control.lease:withFont(function()
            appearance.paint(control.owner, pass, visual(control), hooks, control.meshes, controlShape, function()
              return current() and control.live()
            end)
          end)
        end
      end
    end
    protected.call('ui substitute ' .. plugin.ownerLabel(owner) .. ' panel draw', function()
      appearance.renderProtected(pass, render)
    end)
  end
  local effect
  local function dispose()
    if panel.dead then
      return
    end
    panel.dead, handle.dead, panel.surface.dead = true, true, true
    local oldChrome = chrome
    chrome = nil
    local failures = {}
    local ok, message = pcall(function()
      if oldChrome then
        oldChrome:destroy()
      end
    end)
    if not ok then
      failures[#failures + 1] = tostring(message)
    end
    ok, message = pcall(function()
      panel.cancel(nil, 'surface-dead')
    end)
    if not ok then
      failures[#failures + 1] = tostring(message)
    end
    local ordered = table.clone(panel.controls)
    for index, control in ordered do
      if control.focused then
        table.remove(ordered, index)
        table.insert(ordered, 1, control)
        break
      end
    end
    for _, control in ordered do
      ok, message = pcall(function()
        control.handle:destroy()
      end)
      if not ok then
        failures[#failures + 1] = tostring(message)
      end
    end
    panel.controls, panel.gestures, panel.drawHook = {}, {}, nil
    for _, operation in
      {
        function()
          if panel.frame then
            panel.frame.dispose()
          end
        end,
        function()
          drawing.clear(panel.frameMeshes)
        end,
        function()
          appearance.release(panel)
        end,
      }
    do
      ok, message = pcall(operation)
      if not ok then
        failures[#failures + 1] = tostring(message)
      end
    end
    panel.shape, panel.contour = nil, nil
    local index = table.find(provider.panels, panel)
    if index then
      table.remove(provider.panels, index)
    end
    if #failures > 0 then
      error(table.concat(failures, '\n'), 0)
    end
  end
  function handle.destroy(_: ui.Panel): boolean
    if panel.dead then
      return false
    end
    local release = effect
    effect = nil
    local cleaned, cleanup = pcall(dispose)
    local released, failure = pcall(function()
      if release then
        release:dispose()
      end
    end)
    if not cleaned then
      error(tostring(cleanup) .. (if released then '' else '\nresource release: ' .. tostring(failure)), 0)
    end
    if not released then
      error(failure, 0)
    end
    return true
  end
  function handle.button(_: ui.Panel, controlOwner: ui.Owner, value: ui.ButtonOptions): ui.Button
    return controls.new(panel, controlOwner, value, 'button')
  end
  function handle.textField(_: ui.Panel, controlOwner: ui.Owner, value: ui.TextFieldOptions): ui.TextField
    return controls.new(panel, controlOwner, value, 'text-field')
  end
  function handle.choice(_: ui.Panel, controlOwner: ui.Owner, value: ui.ChoiceOptions): ui.Choice
    return controls.new(panel, controlOwner, value, 'choice')
  end
  function handle.list(_: ui.Panel, controlOwner: ui.Owner, value: ui.ListOptions): ui.List
    return controls.new(panel, controlOwner, value, 'list')
  end
  function handle.region(_: ui.Panel, controlOwner: ui.Owner, value: ui.RegionOptions): ui.Region
    return controls.new(panel, controlOwner, value, 'region')
  end
  panel.handle = handle
  local _, acquired = provider.context:resource(owner, function()
    provider.panels[#provider.panels + 1] = panel
    return handle, dispose
  end)
  effect = acquired
  if options.titlebar then
    local ok, failure = pcall(function()
      handle:setTitlebar(options.titlebar)
    end)
    if not ok then
      handle:destroy()
      error(failure, 0)
    end
  end
  return handle
end

return panels

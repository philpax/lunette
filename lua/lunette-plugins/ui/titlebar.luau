-- Owns shared titlebar drawing, action controls, and an owning surface's trigger-drag background.
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local themesContract = require '@lunette-contracts/theme'
local surfaces = require '@lunette-contracts/surfaces'
local quad = require '@lunette-contracts/quad'
local styleDefinition = require './titlebar-style'
local draw = require './draw'
local cleanup = require '@lunette-plugins/lifecycle/cleanup'
local titlebarOptions = require './titlebar-options'
local titlebarDraw = require './titlebar-draw'
local rounded = require '@lunette-plugins/graphics/rounded-geometry'
local drawing = require '@lunette-plugins/graphics/rounded-drawing'
local vocabulary = require '@lunette-contracts/vocabulary'
local frameStyle = require '@lunette-contracts/schemas/frame-style'
local records = require './panel-state'

local titlebar = {}

-- One provider activation shares these with every titlebar it creates.
export type Provider = {
  read context: plugin.Context,
  read service: ui.Service,
  read surfaces: surfaces.Service,
  read style: ui.TitlebarStyleOverrides,
  read themes: themesContract.Service,
  read contour: (ui.Panel, records.Contour) -> (),
  read size: (ui.Panel) -> (number, number),
}

function titlebar.new(
  provider: Provider,
  owner: ui.Owner,
  name: string,
  target: vocabulary.Surface,
  given: ui.TitlebarOptions,
  visible: (() -> boolean)?
): ui.Titlebar
  local context, themes = provider.context, provider.themes
  context:checkOwner(owner)
  assert(type(name) == 'string' and name ~= '', 'ui titlebar: name is non-empty')
  assert(target.pose and target.width and target.height, 'ui titlebar: target has panel geometry')
  local options = titlebarOptions.parse(given)
  local function resolveStyle(current: ui.TitlebarOptions): ui.TitlebarStyleOverrides
    return styleDefinition.inherit(
      styleDefinition.inherit(styleDefinition.global(themes:current().theme), provider.style),
      current.style
    )
  end
  local spec = resolveStyle(options)
  local style = styleDefinition.materialize(spec, themes:font(spec.font))
  local themeRevision = themes:current().revision
  local dead, highlighted = false, false
  local handleFields: { dead: boolean } = { dead = false }
  local function refresh(force: boolean?): ()
    if dead or not context:active() or not context:owns(owner) then
      return
    end
    local snapshot = themes:current()
    if not force and snapshot.revision == themeRevision then
      return
    end
    local nextSpec = resolveStyle(options)
    local nextStyle = styleDefinition.materialize(nextSpec, themes:font(nextSpec.font))
    spec, style, themeRevision = nextSpec, nextStyle, snapshot.revision
  end
  local pose = lovr.math.newMat4()
  local toolbar: ui.Panel? = nil
  local offer: plugin.Effect? = nil
  local release: plugin.Effect? = nil
  type ActionControl = { handle: ui.Button, label: string, bounds: ui.Bounds, enabled: boolean }
  local controls: { [string]: ActionControl } = {}
  local actions: { ui.TitlebarAction } = {}
  local widths: { number } = {}
  local reserved = 0
  local meshes = drawing.newCache()
  local attachment: vocabulary.FrameAttachment? = nil
  local attachedStyle: vocabulary.FrameStyle? = nil
  local joined = false
  local headerKey = ''
  local function live(): boolean
    return not dead and context:active() and context:owns(owner) and not target.dead and (visible == nil or visible())
  end
  local function offset(): number
    return (target.height or 0) / 2 + (if joined then 0 else style.margin) + style.barHeight / 2
  end
  local function place(): ()
    local current = target.pose
    if current then
      pose:set(current):translate(0, offset(), 0)
    end
  end
  local actionHeight = style.barHeight
  local actionFace = style.font
  local toolbarPose: { number } = {}
  local function sync(): ()
    refresh()
    local current = attachment
    if not live() then
      attachment, attachedStyle, joined = nil, nil, false
      if current then
        current:dispose()
      end
    else
      local nextStyle: vocabulary.FrameStyle = {
        headerHeight = style.barHeight,
        headerRadius = style.cornerRadius,
        borderThickness = style.borderThickness,
        borderDepth = style.borderDepth,
        borderColor = if highlighted then style.borderHighlightColor else style.borderColor,
      }
      if not current and target.attachFrame then
        current = target:attachFrame(owner, nextStyle)
        attachment, attachedStyle = current, nextStyle
      elseif current and (not attachedStyle or not frameStyle.equal(attachedStyle, nextStyle)) then
        current:update(nextStyle)
        attachedStyle = nextStyle
      end
      joined = current ~= nil and current:isJoined()
    end
    local panel = toolbar
    if dead or not panel or panel.dead then
      return
    end
    -- The theme service caches one face per font specification, so the face identifies the specification.
    if actionHeight ~= style.barHeight or actionFace ~= style.font then
      actionHeight, actionFace = style.barHeight, style.font
      panel:setTheme { font = spec.font, fontSize = actionHeight * 1000 * 0.4, padding = 3 }
    end
    place()
    local width = target.width or 0
    local closeWidth = if options.onClose then math.min(width, style.barHeight) else 0
    local extra = options.actions or {}
    actions, widths, reserved = {}, {}, 0
    for _, action in extra do
      actions[#actions + 1] = action
      widths[#widths + 1] = math.min((width - closeWidth) / (#extra + 1), style.barHeight * (action.width or 3))
    end
    if options.onClose then
      actions[#actions + 1] = { id = options.closeId or 'close', label = 'X', run = options.onClose }
      widths[#widths + 1] = closeWidth
    end
    for _, extent in widths do
      reserved += extent
    end
    local used: { [string]: boolean } = {}
    local x = 0
    for index, action in actions do
      used[action.id] = true
      local control = controls[action.id]
      if control and control.label ~= action.label then
        control.handle:destroy()
        controls[action.id] = nil
        control = nil
      end
      local bounds = { x = x * 1000, y = 0, width = widths[index] * 1000, height = style.barHeight * 1000 }
      if not control then
        local id = action.id
        local handle = panel:button {
          id = id,
          label = action.label,
          bounds = bounds,
          enabled = action.enabled,
          onActivate = function(): ()
            if live() then
              for _, current in actions do
                if current.id == id and current.enabled ~= false then
                  current.run()
                  return
                end
              end
            end
          end,
        }
        local created: ActionControl =
          { handle = handle, label = action.label, bounds = bounds, enabled = action.enabled ~= false }
        control = created
        controls[id] = created
      else
        local old = control.bounds
        if old.x ~= bounds.x or old.y ~= bounds.y or old.width ~= bounds.width or old.height ~= bounds.height then
          control.bounds = bounds
          control.handle:setBounds(bounds)
        end
        if control.enabled ~= (action.enabled ~= false) then
          control.enabled = action.enabled ~= false
          control.handle:setEnabled(control.enabled)
        end
      end
      x += widths[index]
    end
    for id, control in controls do
      if not used[id] then
        control.handle:destroy()
        controls[id] = nil
      end
    end
    local toolbarWidth = math.max(reserved, 0.001)
    local currentWidth, currentHeight = provider.size(panel)
    if currentWidth ~= toolbarWidth or currentHeight ~= style.barHeight then
      panel:setSize(toolbarWidth, style.barHeight, toolbarWidth * 1000, style.barHeight * 1000)
    end
    local profile = titlebarDraw.profile(width, style.barHeight, style.cornerRadius, joined)
    local headerBounds =
      { x = -(width - toolbarWidth) * 1000, y = 0, width = width * 1000, height = style.barHeight * 1000 }
    local function logical(corner: rounded.Corner): rounded.Corner
      return { x = corner.x * 1000, y = corner.y * 1000 }
    end
    local logicalProfile: rounded.Profile = {
      topLeft = logical(profile.topLeft),
      topRight = logical(profile.topRight),
      bottomRight = logical(profile.bottomRight),
      bottomLeft = logical(profile.bottomLeft),
    }
    local key = rounded.key(headerBounds, logicalProfile)
    if key ~= headerKey then
      headerKey = key
      drawing.clear(meshes)
      provider.contour(panel, { bounds = headerBounds, profile = logicalProfile })
    end
    local nextPose = lovr.math.newMat4(pose):translate(width / 2 - toolbarWidth / 2, 0, draw.depth.layer)
    local values = { nextPose:unpack(true) }
    local moved = #toolbarPose ~= #values
    for index, value in values do
      moved = moved or toolbarPose[index] ~= value
    end
    if moved then
      toolbarPose = values
      panel:setPose(nextPose)
    end
    panel:setVisible(live() and #actions > 0)
  end
  local function destroy(): boolean
    if dead then
      return false
    end
    dead = true
    local panel, offered, inverse, oldAttachment = toolbar, offer, release, attachment
    toolbar, offer, release, attachment = nil, nil, nil, nil
    handleFields.dead = true
    cleanup.run('ui titlebar cleanup', {
      function(): ()
        if panel then
          panel:destroy()
        end
      end,
      function(): ()
        if offered then
          offered:dispose()
        end
      end,
      function(): ()
        if oldAttachment then
          oldAttachment:dispose()
        end
      end,
      function(): ()
        drawing.clear(meshes)
      end,
      function(): ()
        if inverse then
          inverse:dispose()
        end
      end,
    })
    return true
  end
  local function raycast(
    _self: vocabulary.Surface,
    origin: vector,
    direction: vector,
    backFace: boolean?
  ): (number?, number?, number?)
    sync()
    if not live() then
      return nil, nil, nil
    end
    local width = target.width or 0
    local x, y, distance = quad.hit(
      { pose = pose, width = width, height = style.barHeight, pixelWidth = 1, pixelHeight = 1, backFace = backFace },
      origin,
      direction
    )
    local profile = titlebarDraw.profile(width, style.barHeight, style.cornerRadius, joined)
    if
      x
      and y
      and not rounded.contains(
        rounded.perimeter({ x = 0, y = 0, width = width, height = style.barHeight }, profile),
        x * width,
        y * style.barHeight
      )
    then
      return nil, nil, nil
    end
    if x and x >= 1 - reserved / width then
      return nil, nil, nil
    end
    return x, y, distance
  end
  local methods = {
    raycast = raycast,
    setPose = function(_self: vocabulary.Surface, nextPose: Mat4): ()
      if live() and target.setPose then
        target:setPose(lovr.math.newMat4(nextPose):translate(0, -offset(), 0))
        sync()
      end
    end,
    setHighlighted = function(_self: vocabulary.Surface, value: boolean): ()
      highlighted = value
      sync()
    end,
  }
  -- The drag surface derives its fields from the target on every read, because the target moves and resizes on its own.
  local bar = table.freeze(setmetatable({}, {
    __index = function(_self: unknown, key: string): unknown
      if key == 'dead' then
        return not live()
      elseif key == 'kind' then
        return target.kind
      elseif key == 'source' then
        return if target.kind then target.source else nil
      elseif key == 'pose' then
        place()
        return pose
      elseif key == 'width' then
        return target.width
      elseif key == 'height' then
        return style.barHeight
      elseif key == 'grabbable' or key == 'triggerGrabbable' then
        return options.draggable ~= false
      end
      return methods[key]
    end,
  })) :: vocabulary.Surface
  local handle: ui.Titlebar = {
    dead = false,
    sync = function(_self: ui.Titlebar): ()
      sync()
    end,
    update = function(_self: ui.Titlebar, nextOptions: ui.TitlebarOptions): ()
      if dead then
        return
      end
      local parsed = titlebarOptions.parse(nextOptions)
      local previous, previousStyle = options, style
      options = parsed
      local ok, failure = pcall(refresh, true)
      if not ok then
        if style == previousStyle then
          options = previous
        end
        error(failure, 0)
      end
      sync()
    end,
    destroy = function(_self: ui.Titlebar): boolean
      return destroy()
    end,
    draw = function(_self: ui.Titlebar, pass: Pass): ()
      sync()
      if not live() then
        return
      end
      local width, height, targetPose = target.width, target.height, target.pose
      if not width or not height or not targetPose then
        return
      end
      titlebarDraw.render(pass, meshes, target, pose, style, options.title, reserved, highlighted, joined)
      if toolbar then
        toolbar:draw(pass)
      end
    end,
  }
  handleFields = (handle :: unknown) :: { dead: boolean }
  local ok, failure = pcall(function(): ()
    toolbar = provider.service:newPanel(owner, {
      name = name,
      width = 0.001,
      height = style.barHeight,
      logicalWidth = 1,
      logicalHeight = style.barHeight * 1000,
      visible = false,
      grabTarget = target,
      theme = { font = spec.font, fontSize = style.barHeight * 1000 * 0.4, padding = 3 },
    })
    offer = provider.surfaces:offer(context, {
      name = name .. '/drag',
      list = function(): { vocabulary.Surface }
        sync()
        return if live() then { bar } else {}
      end,
    })
    release = context:acquire(owner, function(): () -> ()
      return function(): ()
        destroy()
      end
    end)
    sync()
  end)
  if not ok then
    destroy()
    error(failure, 0)
  end
  return handle
end

return titlebar

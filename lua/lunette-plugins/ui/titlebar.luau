-- Owns shared titlebar drawing, action controls, and an owning surface's trigger-drag background.
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local surface = require '@lunette-contracts/surface'
local surfaces = require '@lunette-contracts/surfaces'
local quad = require '@lunette-contracts/quad'
local styleDefinition = require './titlebar-style'
local passState = require '@lunette-plugins/pass-state'
local depth = require './depth'

local titlebar = {}

function titlebar.options(given: ui.TitlebarOptions): ui.TitlebarOptions
  assert(type(given) == 'table' and getmetatable(given) == nil, 'ui titlebar: options are a plain table')
  plugin.rejectUnknownFields('ui titlebar', given, {
    title = true,
    onClose = true,
    closeId = true,
    actions = true,
    style = true,
    draggable = true,
  }, 'titlebar option fields', 3)
  assert(type(given.title) == 'string', 'ui titlebar: title is a string')
  assert(given.onClose == nil or type(given.onClose) == 'function', 'ui titlebar: onClose is a function')
  assert(
    given.closeId == nil or (type(given.closeId) == 'string' and given.closeId ~= ''),
    'ui titlebar: closeId is non-empty'
  )
  assert(given.draggable == nil or type(given.draggable) == 'boolean', 'ui titlebar: draggable is a boolean')
  local actions: { ui.TitlebarAction } = {}
  local ids: { [string]: boolean } = {}
  if given.onClose then
    ids[given.closeId or 'close'] = true
  end
  if given.actions ~= nil then
    assert(type(given.actions) == 'table' and getmetatable(given.actions) == nil, 'ui titlebar: actions are an array')
    local count = 0
    for key in given.actions do
      assert(
        type(key) == 'number' and key % 1 == 0 and key >= 1 and key <= #given.actions,
        'ui titlebar: actions are dense'
      )
      count += 1
    end
    assert(count == #given.actions, 'ui titlebar: actions are dense')
    for _, action in given.actions do
      assert(type(action) == 'table' and getmetatable(action) == nil, 'ui titlebar: action is a plain table')
      plugin.rejectUnknownFields('ui titlebar action', action, {
        id = true,
        label = true,
        width = true,
        enabled = true,
        run = true,
      }, 'id, label, width, enabled, and run', 3)
      assert(
        type(action.id) == 'string' and action.id ~= '' and not ids[action.id],
        'ui titlebar: action ids are unique'
      )
      assert(type(action.label) == 'string', 'ui titlebar: action label is a string')
      assert(type(action.run) == 'function', 'ui titlebar: action run is a function')
      assert(action.enabled == nil or type(action.enabled) == 'boolean', 'ui titlebar: action enabled is a boolean')
      assert(
        action.width == nil or (action.width > 0 and action.width < math.huge),
        'ui titlebar: action width is positive'
      )
      ids[action.id] = true
      actions[#actions + 1] = table.freeze(table.clone(action))
    end
  end
  return table.freeze {
    title = given.title,
    onClose = given.onClose,
    closeId = given.closeId,
    actions = table.freeze(actions),
    style = if given.style then styleDefinition.overrides.parse(given.style) else nil,
    draggable = given.draggable,
  }
end

function titlebar.new(
  context: plugin.Context,
  owner: ui.Owner,
  name: string,
  target: surface.Surface,
  given: ui.TitlebarOptions,
  visible: (() -> boolean)?,
  service: ui.Service,
  offers: surfaces.Service,
  defaultStyle: ui.TitlebarStyle
): ui.Titlebar
  context:checkOwner(owner)
  assert(type(name) == 'string' and name ~= '', 'ui titlebar: name is non-empty')
  assert(target.pose and target.width and target.height, 'ui titlebar: target has panel geometry')
  local options = titlebar.options(given)
  local function resolveStyle(current: ui.TitlebarOptions): ui.TitlebarStyle
    return styleDefinition.schema.resolve(current.style or {}, defaultStyle)
  end
  local style = resolveStyle(options)
  local dead, highlighted = false, false
  local pose = lovr.math.newMat4()
  local toolbar: ui.Panel? = nil
  local offer: plugin.Effect? = nil
  local release: plugin.Effect? = nil
  type ActionControl = { handle: ui.Button, label: string, bounds: ui.Bounds, enabled: boolean }
  local controls: { [string]: ActionControl } = {}
  local actions: { ui.TitlebarAction } = {}
  local widths: { number } = {}
  local reserved = 0
  local function live(): boolean
    return not dead and context:active() and context:owns(owner) and not target.dead and (visible == nil or visible())
  end
  local function offset(): number
    return (target.height or 0) / 2 + style.margin + style.barHeight / 2
  end
  local function place(): ()
    local current = target.pose
    if current then
      pose:set(current):translate(0, offset(), 0)
    end
  end
  local function sync(): ()
    local panel = toolbar
    if dead or not panel or panel.dead then
      return
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
        local handle = panel:button(owner, {
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
        })
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
    local description = panel:describe()
    if description.width ~= toolbarWidth or description.height ~= style.barHeight then
      panel:setSize(toolbarWidth, style.barHeight, toolbarWidth * 1000, style.barHeight * 1000)
    end
    panel:setPose(lovr.math.newMat4(pose):translate(width / 2 - toolbarWidth / 2, 0, depth.layer))
    panel:setVisible(live() and #actions > 0)
  end
  local function destroy(): boolean
    if dead then
      return false
    end
    dead = true
    local panel, offered, inverse = toolbar, offer, release
    toolbar, offer, release = nil, nil, nil
    local failures: { string } = {}
    for _, operation in
      {
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
          if inverse then
            inverse:dispose()
          end
        end,
      }
    do
      local ok, failure = pcall(function(): boolean
        operation()
        return true
      end)
      if not ok then
        failures[#failures + 1] = tostring(failure)
      end
    end
    if #failures > 0 then
      error('ui titlebar cleanup: ' .. table.concat(failures, '; '), 0)
    end
    return true
  end
  local function raycast(
    _self: surface.Surface,
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
    if x and x >= 1 - reserved / width then
      return nil, nil, nil
    end
    return x, y, distance
  end
  local methods = {
    raycast = raycast,
    setPose = function(_self: surface.Surface, nextPose: Mat4): ()
      if live() and target.setPose then
        target:setPose(lovr.math.newMat4(nextPose):translate(0, -offset(), 0))
        sync()
      end
    end,
    setHighlighted = function(_self: surface.Surface, value: boolean): ()
      highlighted = value
    end,
  }
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
  })) :: surface.Surface
  local handle = table.freeze(setmetatable({}, {
    __index = function(_self: unknown, key: string): unknown
      if key == 'dead' then
        return dead
      end
      return ({
        sync = function(_self: ui.Titlebar): ()
          sync()
        end,
        update = function(_self: ui.Titlebar, nextOptions: ui.TitlebarOptions): ()
          if not dead then
            options = titlebar.options(nextOptions)
            style = resolveStyle(options)
            sync()
          end
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
          passState.withRestore(pass, function(): ()
            pass:setShader()
            pass:setMaterial(nil)
            pass:setFont(lovr.graphics.getDefaultFont())
            pass:setDepthTest 'gequal'
            pass:setDepthWrite(true)
            local border = if highlighted then style.borderHighlightColor else style.borderColor
            pass:setColor(border[1], border[2], border[3], border[4])
            pass:plane(
              lovr.math
                .mat4(targetPose)
                :translate(0, 0, -style.borderDepth)
                :scale(width + style.borderThickness * 2, height + style.borderThickness * 2, 1),
              'fill',
              1,
              1
            )
            local background = if highlighted then style.barHighlightColor else style.barColor
            pass:setColor(background[1], background[2], background[3], background[4])
            pass:plane(lovr.math.mat4(pose):scale(width, style.barHeight, 1), 'fill', 1, 1)
            if width > reserved and options.title ~= '' then
              pass:setDepthWrite(false)
              local foreground = style.titleColor
              pass:setColor(foreground[1], foreground[2], foreground[3], foreground[4])
              pass:text(
                options.title,
                lovr.math.mat4(pose):translate(-reserved / 2, 0, depth.layer):scale(vector.pack(style.titleHeight)),
                (width - reserved) / style.titleHeight,
                'center',
                'middle'
              )
            end
          end)
          if toolbar then
            toolbar:draw(pass)
          end
        end,
      })[key]
    end,
  })) :: ui.Titlebar
  local ok, failure = pcall(function(): ()
    toolbar = service:newPanel(owner, {
      name = name,
      width = 0.001,
      height = style.barHeight,
      logicalWidth = 1,
      logicalHeight = style.barHeight * 1000,
      visible = false,
      grabTarget = target,
      theme = { fontSize = style.barHeight * 1000 * 0.4, padding = 3 },
    })
    offer = offers:offer(context, {
      name = name .. '/drag',
      list = function(): { surface.Surface }
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

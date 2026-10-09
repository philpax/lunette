-- Visibility intent and focus identity belong here; keyboard layout and input remain the keyboard provider's.
local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/keyboard-display'
local focus = require '@lunette-contracts/focus'
local keyboard = require '@lunette-contracts/keyboard'
local frame = require '@lunette-contracts/frame'
local surfaces = require '@lunette-contracts/surfaces'
local ui = require '@lunette-contracts/ui'
local listeners = require '@lunette-plugins/listeners'
local place = require '@lunette-plugins/desktop/keyboard/placement'
local config = require '@lunette-plugins/desktop/keyboard/config'
local vocabulary = require '@lunette-contracts/vocabulary'

return function(context: plugin.Context, settings: config.Settings): contract.Service
  local keys: keyboard.Service = context:require(keyboard.capability)
  local routes: focus.Service = context:require(focus.capability)
  local offers: surfaces.Service = context:require(surfaces.capability)
  local clock: frame.Service = context:require(frame.capability)
  local widgets = context:require(ui.capability)
  local board: keyboard.Keyboard? = nil
  local bar: ui.Titlebar? = nil
  local stopped, visible, manual = false, false, false
  -- The local target whose focus requested automatic visibility.
  local auto: focus.TargetHandle? = nil
  local currentTarget: focus.TargetHandle? = nil
  local revision = 0
  local subscribers = listeners.new<<contract.Listener>>(context)

  local function live(): boolean
    return not stopped and context:active()
  end
  local function notify(reason: 'show' | 'hide' | 'user-hide' | 'destroy'): ()
    revision += 1
    local own = revision
    local change: contract.Change = table.freeze { visible = visible, reason = reason }
    -- A listener that changes visibility publishes a newer change, so later listeners skip this stale one.
    subscribers:each('keyboard-display: a change listener', function(listener: contract.Listener): ()
      listener.run(change)
    end, function(): boolean
      return revision == own
    end)
  end
  local function clearIntent(): ()
    manual, auto = false, nil
  end
  -- Blurs the local target only while it still holds focus, so a newer focus is never blurred.
  local function blur(target: focus.TargetHandle?): ()
    if target and not target.dead and routes:focused() == target and not target:blur() then
      error('keyboard-display: current local target refused blur', 0)
    end
  end
  local function boardChanged(change: keyboard.VisibilityChange): ()
    visible = change.visible
    if bar then
      bar:sync()
    end
    if change.reason == 'user-hide' then
      clearIntent()
      blur(currentTarget)
      if live() and not visible then
        notify 'user-hide'
      end
    elseif change.reason == 'destroy' then
      board = nil
      if bar then
        local old = bar
        bar = nil
        old:destroy()
      end
      clearIntent()
      notify 'destroy'
    else
      notify(change.reason)
    end
  end
  local hide: () -> boolean
  -- Board events are ignored until the board is assigned, so creation hides it silently.
  local function newBoard(): keyboard.Keyboard
    local created: keyboard.Keyboard? = nil
    local target = keys:new(context, {
      onVisibilityChanged = function(change: keyboard.VisibilityChange): ()
        if live() and created ~= nil and board == created then
          boardChanged(change)
        end
      end,
    })
    created = target
    target:setVisible(false)
    board = target
    bar = widgets:newTitlebar(context, 'desktop/keyboard/titlebar', target, {
      title = 'Keyboard',
      onClose = function(): ()
        hide()
      end,
    }, function(): boolean
      return live() and visible and not target.dead
    end)
    return target
  end
  local function setVisible(show: boolean): boolean
    if not live() then
      return false
    end
    local target = board
    if show and (not target or target.dead) then
      target = newBoard()
    end
    if not target or target.dead then
      return not show
    end
    if target.visible == show then
      visible = show
      return true
    end
    if show then
      place(target, settings.placement)
    end
    target:setVisible(show)
    return live() and not target.dead and target.visible == show
  end
  local function show(): boolean
    if not live() then
      return false
    end
    manual = true
    return setVisible(true)
  end
  hide = function(): boolean
    if not live() then
      return false
    end
    clearIntent()
    blur(currentTarget)
    return setVisible(false) and not visible
  end

  context:effect(function(): () -> ()
    return function(): ()
      stopped, visible = true, false
      notify 'destroy'
      subscribers:clear()
    end
  end)
  routes:onChanged(context, {
    run = function(change: focus.Change): ()
      if not live() then
        return
      end
      local target = if change.kind == 'local' then change.target else nil
      currentTarget = target
      if target and change.wantsKeyboard and not target.dead then
        auto = target
        setVisible(true)
      elseif auto then
        auto = nil
        if not manual then
          setVisible(false)
        end
      end
    end,
  })
  offers:offer(context, {
    name = 'keyboard-display',
    list = function(): { vocabulary.Surface }
      local target = board
      return if live() and visible and target and not target.dead then { target } else {}
    end,
  })
  clock:onDraw(context, {
    phase = 'scene',
    order = 1,
    run = function(pass: Pass): ()
      local target = board
      if live() and visible and target and not target.dead then
        if bar then
          bar:draw(pass)
        end
        target:draw(pass)
      end
    end,
  })

  local service: contract.Service = {
    show = function(_self: contract.Service): boolean
      return show()
    end,
    hide = function(_self: contract.Service): boolean
      return hide()
    end,
    toggle = function(_self: contract.Service): boolean
      return if visible then hide() else show()
    end,
    isVisible = function(_self: contract.Service): boolean
      return live() and visible
    end,
    onChanged = function(_self: contract.Service, owner: contract.Owner, listener: contract.Listener): plugin.Effect
      context:checkOwner(owner)
      if not live() then
        error('keyboard-display onChanged: service is dead', 2)
      end
      if type(listener) ~= 'table' then
        error('keyboard-display onChanged: listener is a plain table', 2)
      end
      plugin.rejectUnknownFields('keyboard-display onChanged', listener, { 'run' }, 2)
      if type(listener.run) ~= 'function' then
        error('keyboard-display onChanged: run is a plain callback', 2)
      end
      return subscribers:add(owner, { run = listener.run })
    end,
  }
  return table.freeze(service)
end

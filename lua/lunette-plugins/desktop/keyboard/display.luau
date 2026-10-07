-- Visibility intent and focus identity belong here; keyboard layout and input remain the keyboard provider's.
local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/keyboard-display'
local focus = require '@lunette-contracts/focus'
local keyboard = require '@lunette-contracts/keyboard'
local frame = require '@lunette-contracts/frame'
local surfaces = require '@lunette-contracts/surfaces'
local surface = require '@lunette-contracts/surface'
local protected = require '@lunette-plugins/protected'
local place = require '@lunette-plugins/desktop/keyboard/placement'
local config = require '@lunette-plugins/desktop/keyboard/config'

type Listener = { owner: contract.Owner, run: ((contract.Change) -> ())? }
type Hide = { intentRevision: number, changed: boolean }

return function(context: plugin.Context, settings: config.Settings): contract.Service
  local keys: keyboard.Service = context:require(keyboard.capability)
  local routes: focus.Service = context:require(focus.capability)
  local offers: surfaces.Service = context:require(surfaces.capability)
  local clock: frame.Service = context:require(frame.capability)
  local board: keyboard.Keyboard? = nil
  local stopped, visible, manualVisible = false, false, false
  local initializing, requestedVisible = false, false
  local publicHide: Hide? = nil
  local visibilityHide: Hide? = nil
  local blurringRevision: number? = nil
  local currentTarget: focus.TargetHandle? = nil
  local currentRevision = 0
  local autoTarget: focus.TargetHandle? = nil
  local autoRevision = 0
  local revision, intentRevision = 0, 0
  local listeners: { Listener } = {}

  local function live(): boolean
    return not stopped and context:active()
  end
  local function localTarget(): focus.TargetHandle?
    local target = currentTarget
    return if target and not target.dead then target else nil
  end
  local function notify(reason: 'show' | 'hide' | 'user-hide' | 'destroy'): ()
    revision += 1
    local ownRevision = revision
    local change: contract.Change = table.freeze {
      visible = visible,
      reason = reason,
      target = localTarget(),
      revision = revision,
    }
    for _, listener in ipairs(table.clone(listeners)) do
      local run = listener.run
      if run and context:owns(listener.owner) then
        protected.call('keyboard-display listener (' .. plugin.ownerLabel(listener.owner) .. ')', function(): ()
          run(change)
        end)
        if revision ~= ownRevision then
          return
        end
      end
    end
  end
  local function clearIntent(): number
    manualVisible, requestedVisible = false, false
    autoTarget, autoRevision = nil, 0
    intentRevision += 1
    return intentRevision
  end
  local function blur(target: focus.TargetHandle?, focusRevision: number): ()
    if not live() or not target or target.dead then
      return
    end
    local beforeQuery = routes:revision()
    if beforeQuery ~= focusRevision then
      return
    end
    local focused = routes:focused()
    if focused ~= target then
      return
    end
    local afterQuery = routes:revision()
    if afterQuery ~= focusRevision then
      return
    end
    blurringRevision = focusRevision
    local ok, accepted = pcall(function(): boolean
      return target:blur()
    end)
    blurringRevision = nil
    if not ok then
      error(accepted, 0)
    end
    if not accepted then
      error('keyboard-display: current local target refused blur', 0)
    end
  end
  local function boardChanged(change: keyboard.VisibilityChange): ()
    if not live() or initializing then
      return
    end
    visible = change.visible
    if change.reason == 'user-hide' then
      local target, focusRevision = localTarget(), currentRevision
      local ownIntent = clearIntent()
      local ok, failure = pcall(function(): ()
        blur(target, focusRevision)
      end)
      if live() and intentRevision == ownIntent and not visible then
        notify 'user-hide'
      end
      if not ok then
        error(failure, 0)
      end
    elseif change.reason == 'destroy' then
      board = nil
      clearIntent()
      notify 'destroy'
    else
      local pending = visibilityHide
      if change.reason == 'hide' and pending then
        pending.changed = true
      else
        notify(change.reason)
      end
    end
  end
  local function getBoard(): keyboard.Keyboard?
    local existing = board
    if existing and not existing.dead then
      return existing
    end
    if not live() or initializing then
      return nil
    end
    initializing = true
    local created: keyboard.Keyboard? = nil
    local ok, failure = pcall(function(): ()
      created = keys:new(context, { onVisibilityChanged = boardChanged })
      if created then
        board = created
        created:setVisible(false)
      end
    end)
    initializing = false
    local target = created
    if not ok or not live() then
      board = nil
      if target and not target.dead then
        protected.call('keyboard-display: partial keyboard cleanup', function(): ()
          target:destroy()
        end)
      end
      if not ok then
        error(failure, 0)
      end
      return nil
    end
    return if target and not target.dead then target else nil
  end
  local function setVisible(show: boolean): boolean
    if not live() then
      return false
    end
    requestedVisible = show
    local target = if show then getBoard() else board
    if not target or target.dead then
      return not show
    end
    local requested = requestedVisible
    if target.visible == requested then
      visible = requested
      return requested == show
    end
    if requested then
      place(target, settings.placement)
    end
    local previousHide = visibilityHide
    local pending = publicHide
    visibilityHide = if not requested and pending and pending.intentRevision == intentRevision then pending else nil
    local ok, failure = pcall(function(): ()
      target:setVisible(requested)
    end)
    visibilityHide = previousHide
    if not ok then
      error(failure, 0)
    end
    return live() and not target.dead and target.visible == show
  end
  local function show(): boolean
    if not live() then
      return false
    end
    manualVisible = true
    intentRevision += 1
    return setVisible(true)
  end
  local function hide(): boolean
    if not live() then
      return false
    end
    local target, focusRevision = localTarget(), currentRevision
    local ownIntent = clearIntent()
    local previousHide = publicHide
    local pending: Hide = { intentRevision = ownIntent, changed = false }
    publicHide = pending
    local failures: { string } = {}
    local hidden = false
    local ok, failure = pcall(function(): ()
      hidden = setVisible(false)
    end)
    if not ok then
      failures[#failures + 1] = tostring(failure)
    end
    if live() and intentRevision == ownIntent then
      local blurred, blurFailure = pcall(function(): ()
        blur(target, focusRevision)
      end)
      if not blurred then
        failures[#failures + 1] = tostring(blurFailure)
      end
    end
    publicHide = previousHide
    if pending.changed and live() and intentRevision == pending.intentRevision and not visible then
      notify 'hide'
    end
    if #failures > 0 then
      error(table.concat(failures, '\n'), 0)
    end
    return hidden and live() and not visible
  end

  context:effect(function(): () -> ()
    return function(): ()
      if stopped then
        return
      end
      stopped, visible = true, false
      clearIntent()
      currentTarget = nil
      local target = board
      board = nil
      local ok, failure = pcall(function(): ()
        if target and not target.dead then
          target:destroy()
        end
      end)
      notify 'destroy'
      for _, listener in ipairs(listeners) do
        listener.run = nil
      end
      table.clear(listeners)
      if not ok then
        error(failure, 0)
      end
    end
  end)
  routes:onChanged(context, {
    run = function(change: focus.Change): ()
      if not live() then
        return
      end
      currentTarget = if change.kind == 'local' then change.target else nil
      currentRevision = change.revision
      if blurringRevision and change.kind == 'none' and change.revision == blurringRevision + 1 then
        return
      end
      if change.kind == 'local' and change.wantsKeyboard and change.target and not change.target.dead then
        autoTarget, autoRevision = change.target, change.revision
        intentRevision += 1
        setVisible(true)
      else
        local hadAuto = autoTarget ~= nil and autoRevision > 0
        autoTarget, autoRevision = nil, 0
        intentRevision += 1
        if hadAuto and not manualVisible then
          setVisible(false)
        end
      end
    end,
  })
  offers:offer(context, {
    name = 'keyboard-display',
    list = function(): { surface.Surface }
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
        target:draw(pass)
      end
    end,
  })

  local methods = {
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
      if type(listener) ~= 'table' or getmetatable(listener) ~= nil then
        error('keyboard-display onChanged: listener is a plain table', 2)
      end
      plugin.rejectUnknownFields('keyboard-display onChanged', listener, { run = true }, 'run', 2)
      if type(listener.run) ~= 'function' then
        error('keyboard-display onChanged: run is a plain callback', 2)
      end
      local entry: Listener = { owner = owner, run = listener.run }
      return context:acquire(owner, function(): () -> ()
        listeners[#listeners + 1] = entry
        return function(): ()
          entry.run = nil
          local index = table.find(listeners, entry)
          if index then
            table.remove(listeners, index)
          end
        end
      end)
    end,
  }
  return setmetatable({}, {
    __index = function(_self: unknown, key: string): unknown
      return if key == 'dead' then not live() else methods[key]
    end,
    __newindex = function(): ()
      error('keyboard-display: service is readonly', 2)
    end,
  }) :: contract.Service
end

-- Shows notifications as toasts, beside the panel each concerns or else on a panel that follows the head, queues those
-- beyond the visible limit, and keeps a history of every notification and its actions.

local plugin = require '@lunette-plugin'
local uiHost = require '@lunette-contracts/ui-host'
local uiComponents = require '@lunette-contracts/ui-components'
local frame = require '@lunette-contracts/frame'
local notifications = require '@lunette-contracts/notifications'
local accessibility = require '@lunette-contracts/accessibility'
local inspection = require '@lunette-contracts/inspection'
local protected = require '@lunette-plugins/diagnostics/protected-call'
local ui = require '@lunette-plugins/ui/react'
local config = require '@self/config'

export type Config = config.Config
export type Settings = config.Settings

type Toast = {
  entry: notifications.Entry,
  -- Seconds left, or nil for a toast that stays until it is dismissed.
  remaining: number?,
  hovered: boolean,
  handle: notifications.Handle,
}

-- A panel of toasts: the head-following one, or one beside an anchor panel.
type Group = {
  panel: uiHost.Panel,
  toasts: ui.WritableStore<{ Toast }>,
}

-- Metres between an anchor panel's edge and its toasts.
local ANCHOR_GAP = 0.02

type ToastsProps = { toasts: ui.Store<{ Toast }>, dismiss: (Toast) -> (), hover: (Toast, boolean) -> () }

local Toasts = ui.component('Toasts', function(props: ToastsProps): any
  local c = ui.useComponents()
  local shown = ui.useStore(props.toasts)
  if #shown == 0 then
    return nil
  end
  return c.Column {
    gap = 'sm',
    ui.map(shown, function(toast: Toast): any
      local notification = toast.entry.notification
      local actions = {}
      for index, action in notification.actions or {} do
        actions[index] = {
          id = action.id,
          label = action.label,
          onActivate = function()
            protected.call(`notifications: action {action.id}`, action.run)
            props.dismiss(toast)
          end,
        }
      end
      return c.Toast {
        key = tostring(toast.entry.id),
        title = notification.title,
        body = notification.body,
        level = notification.level,
        actions = actions,
        onHover = function(hovered: boolean)
          props.hover(toast, hovered)
        end,
        onDismiss = function()
          props.dismiss(toast)
        end,
      }
    end),
  }
end)

local function build(context: plugin.Context, settings: Settings): notifications.Service
  local host = context:require(uiHost.capability)
  local components = context:require(uiComponents.capability)
  local frameService = context:require(frame.capability)
  local history = ui.store({} :: { notifications.Entry })
  local visible = ui.store({} :: { Toast })
  local shown: { Toast } = {}
  local queue: { Toast } = {}
  local nextId = 1
  local clock = 0

  -- The accessibility service, while one is loaded: its timing lengthens every toast, and each notification is
  -- announced for assistive plugins. A child consumer keeps a missing provider from disabling notifications.
  local assist: accessibility.Service? = nil
  local announcer: plugin.Owner? = nil
  context:child(plugin.consumer<<{}, {}>>({
    name = 'notifications/accessibility',
    requires = { accessibility.capability },
    init = function(child: plugin.Context, _settings: {}): ()
      local service = child:require(accessibility.capability)
      child:effect(function(): () -> ()
        assist, announcer = service, child
        return function(): ()
          assist, announcer = nil, nil
        end
      end)
    end,
  }).definition)

  local remove: (Toast) -> ()
  local groups: { [uiHost.Panel]: Group } = {}
  local panels = 0

  local function mountGroup(panel: uiHost.Panel, toasts: ui.Store<{ Toast }>): ()
    ui.mount(
      panel,
      Toasts {
        toasts = toasts,
        dismiss = function(toast: Toast)
          remove(toast)
        end,
        hover = function(toast: Toast, hovered: boolean)
          toast.hovered = hovered
        end,
      },
      { components = components, owner = context }
    )
  end

  -- An anchored panel sits beside its anchor's right edge, top-aligned and slightly in front of it.
  local function place(anchor: uiHost.Panel, group: Group): ()
    local anchorWidth, anchorHeight = anchor:size()
    local width, height = group.panel:size()
    group.panel:setPose(
      lovr.math
        .mat4(anchor:pose())
        :translate(anchorWidth / 2 + ANCHOR_GAP + width / 2, (anchorHeight - height) / 2, ANCHOR_GAP / 2)
    )
  end

  -- The live anchor a toast shows beside, or nil for the head-following panel.
  local function anchorOf(toast: Toast): uiHost.Panel?
    local anchor = toast.entry.notification.anchor
    return if anchor and not anchor.dead then anchor else nil
  end

  -- Splits the shown toasts between the head-following panel and a panel beside each anchor, making and ending the
  -- anchored panels as their toasts come and go.
  local function publish(): ()
    local following: { Toast } = {}
    local anchored: { [uiHost.Panel]: { Toast } } = {}
    for _, toast in shown do
      local anchor = anchorOf(toast)
      if anchor then
        local list = anchored[anchor] or {}
        anchored[anchor] = list
        table.insert(list, toast)
      else
        table.insert(following, toast)
      end
    end
    visible:set(following)
    for anchor, group in groups do
      if not anchored[anchor] then
        groups[anchor] = nil
        group.panel:destroy()
      end
    end
    for anchor, list in anchored do
      local group = groups[anchor]
      if not group then
        panels += 1
        local panel = host:newPanel(context, {
          name = `notifications {panels}`,
          size = 'content',
          grabbable = false,
        })
        group = { panel = panel, toasts = ui.store({} :: { Toast }) }
        groups[anchor] = group
        place(anchor, group)
        mountGroup(panel, group.toasts)
      end
      group.toasts:set(list)
    end
  end
  local function fill(): ()
    while #shown < settings.visible and #queue > 0 do
      table.insert(shown, table.remove(queue, 1) :: Toast)
    end
    publish()
  end
  function remove(toast: Toast): ()
    local index = table.find(shown, toast)
    if index then
      table.remove(shown, index)
    else
      index = table.find(queue, toast)
      if index then
        table.remove(queue, index)
      end
    end
    (toast.handle :: any).dead = true
    fill()
  end

  local panel = host:newPanel(context, { name = 'notifications', presentation = 'follow', grabbable = false })
  mountGroup(panel, visible)

  frameService:onUpdate(context, {
    phase = 'scene',
    order = -200,
    run = function(dt: number): ()
      clock += dt
      -- Anchored toasts follow their anchor, and return to the head-following panel when the anchor ends.
      local orphaned = false
      for anchor, group in groups do
        if anchor.dead then
          orphaned = true
        else
          place(anchor, group)
        end
      end
      if orphaned then
        publish()
      end
      local expired: { Toast } = {}
      for _, toast in shown do
        local remaining = toast.remaining
        if remaining and not toast.hovered then
          toast.remaining = remaining - dt
          if remaining - dt <= 0 then
            table.insert(expired, toast)
          end
        end
      end
      for _, toast in expired do
        remove(toast)
      end
    end,
  })

  local service: notifications.Service = {
    notify = function(
      _self: notifications.Service,
      owner: plugin.Owner,
      notification: notifications.Notification
    ): notifications.Handle
      context:checkOwner(owner)
      assert(
        type(notification) == 'table' and type(notification.title) == 'string',
        'notifications: a notification has a title'
      )
      local entry: notifications.Entry = table.freeze {
        id = nextId,
        notification = table.freeze(table.clone(notification)),
        owner = owner,
        time = clock,
      }
      nextId += 1
      local entries = table.clone(history:get())
      table.insert(entries, entry)
      history:set(entries)
      local timeout = notification.timeout or settings.timeout
      local toast: Toast
      local handle = {
        dead = false,
        dismiss = function(_self: notifications.Handle): ()
          remove(toast)
        end,
      }
      toast = {
        entry = entry,
        remaining = if timeout > 0
          then timeout * settings.timing * (if assist then assist.settings:get().timing else 1)
          else nil,
        hovered = false,
        handle = handle :: notifications.Handle,
      }
      table.insert(queue, toast)
      fill()
      local service, poster = assist, announcer
      if service and poster then
        local body = notification.body
        service:announce(poster, {
          text = if body then `{notification.title}. {body}` else notification.title,
          politeness = if notification.level == 'error' then 'assertive' else 'polite',
        })
      end
      -- A notification's toast ends with its owner, so its actions never run after the owner has gone.
      context:acquire(owner, function(): () -> ()
        return function(): ()
          if not handle.dead then
            remove(toast)
          end
        end
      end)
      return handle :: notifications.Handle
    end,
    -- The writable store is published read-only.
    history = history :: any,
    clearHistory = function(_self: notifications.Service): ()
      history:set {}
    end,
    inspect = function(_self: notifications.Service): inspection.Snapshot
      local result: { inspection.Registration } = {}
      for _, toast in shown do
        table.insert(
          result,
          inspection.registration(
            'producer',
            'notifications.notify',
            toast.entry.owner,
            toast.entry.notification.title,
            true,
            {
              shown = true,
            }
          )
        )
      end
      return inspection.snapshot(result, { queued = #queue, history = #history:get() })
    end,
  }
  return service
end

return plugin.provider<<Config, Settings, notifications.Service>> {
  name = 'notifications',
  schema = config.schema,
  capability = notifications.capability,
  requires = { uiHost.capability, uiComponents.capability, frame.capability },
  build = build,
}

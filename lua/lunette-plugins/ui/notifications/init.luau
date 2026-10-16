-- Shows notifications as toasts on a panel that follows the head, queues those beyond the visible limit, and keeps a
-- history of every notification and its actions.

local plugin = require '@lunette-plugin'
local uiHost = require '@lunette-contracts/ui-host'
local uiComponents = require '@lunette-contracts/ui-components'
local frame = require '@lunette-contracts/frame'
local notifications = require '@lunette-contracts/notifications'
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

  local function publish(): ()
    visible:set(table.clone(shown))
  end
  local function fill(): ()
    while #shown < settings.visible and #queue > 0 do
      table.insert(shown, table.remove(queue, 1) :: Toast)
    end
    publish()
  end
  local function remove(toast: Toast): ()
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
  ui.mount(
    panel,
    Toasts {
      toasts = visible,
      dismiss = remove,
      hover = function(toast: Toast, hovered: boolean)
        toast.hovered = hovered
      end,
    },
    { components = components, owner = context }
  )

  frameService:onUpdate(context, {
    phase = 'scene',
    order = -200,
    run = function(dt: number): ()
      clock += dt
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
        remaining = if timeout > 0 then timeout * settings.timing else nil,
        hovered = false,
        handle = handle :: notifications.Handle,
      }
      table.insert(queue, toast)
      fill()
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

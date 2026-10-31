-- The wrist menu's content: one button over the time while closed, and a header with the time and the registered
-- actions while open.
local ui = require '@lunette-plugins/ui/react'
local uiHost = require '@lunette-contracts/ui-host'
local menu = require '@lunette-contracts/menu'
local rows = require './rows'

local view = {}

export type Props = {
  read opened: ui.Store<boolean>,
  read snapshot: ui.Store<rows.Snapshot>,
  -- The local time of day, as hh:mm:ss.
  read time: ui.Store<string>,
  -- Action ids shown as buttons above the closed button, top first.
  read shortcuts: { read [number]: string },
  -- The configured button size in metres. The closed button is a square half this wide.
  read size: number,
  read width: number,
  read height: number,
  read open: () -> (),
  read close: () -> (),
  read invoke: (menu.Descriptor) -> (),
  read shortcut: (menu.Descriptor) -> (),
}

-- The registered actions among the shortcut ids, in their order.
local function shortcutActions(ids: { read [number]: string }, snapshot: rows.Snapshot): { menu.Descriptor }
  local found: { menu.Descriptor } = {}
  for _, id in ids do
    for _, descriptor in snapshot do
      if descriptor.id == id then
        table.insert(found, descriptor)
        break
      end
    end
  end
  return found
end

view.Menu = ui.component('WristMenu', function(props: Props): ui.Child
  local c = ui.useComponents()
  local opened = ui.useStore(props.opened)
  local snapshot = ui.useStore(props.snapshot)
  local time = ui.useStore(props.time)
  if not opened then
    local shortcuts = shortcutActions(props.shortcuts, snapshot)
    -- The shortcuts above and the time below are equally tall, so the menu button sits at the panel's centre, which is
    -- the wrist point. The shortcut row keeps its height when it is empty.
    local band = props.size / 4
    return c.Panel {
      width = props.size / 2,
      padding = 'xs',
      gap = 'xs',
      c.Row {
        key = 'shortcuts',
        height = band,
        gap = 'xs',
        ui.map(shortcuts, function(descriptor: menu.Descriptor): ui.Child
          local icon = descriptor.icon
          -- Quiet buttons with muted ink read as secondary to the menu button. A toggle shows its state by its icon.
          return c.Button {
            key = uiHost.keyOf(descriptor.id),
            label = if icon then nil else descriptor.label,
            variant = 'quiet',
            disabled = not descriptor.enabled,
            grow = 1,
            onActivate = function(): ()
              props.shortcut(descriptor)
            end,
            if icon
              then c.Image {
                key = 'icon',
                source = { kind = 'svg', data = icon },
                tint = 'muted',
                label = descriptor.label,
                height = band * 0.6,
                alignSelf = 'center',
              }
              else nil,
          }
        end),
      },
      c.Column {
        height = props.size / 2,
        c.Button { key = 'open', label = 'Menu', grow = 1, onActivate = props.open },
      },
      c.Column {
        height = band,
        justify = 'center',
        c.Text { key = 'time', text = time, style = 'readout', color = 'muted', align = 'center' },
      },
    }
  end
  local list = rows.rows(snapshot)
  return c.Panel {
    width = props.width,
    height = props.height,
    title = 'Menu',
    detail = time,
    onClose = props.close,
    -- The scroll box sits directly in the panel, so it shrinks to the space below the header rather than growing
    -- the panel to fit every row.
    c.ScrollView {
      grow = 1,
      c.Column {
        padding = 'md',
        if #list == 0
          then c.Text { key = 'empty', text = 'No actions are registered.', style = 'caption', color = 'muted' }
          else c.List {
            key = 'actions',
            ui.map(list, function(row: rows.Row): ui.Child
              if row.kind == 'group' then
                return c.Text {
                  key = row.key,
                  text = string.upper(row.title),
                  style = 'section',
                  color = 'muted',
                }
              end
              local descriptor = row.descriptor
              return c.ListRow {
                key = row.key,
                title = row.title,
                trailing = row.trailing,
                selected = descriptor.selected,
                onActivate = if descriptor.enabled
                  then function(): ()
                    props.invoke(descriptor)
                  end
                  else nil,
              }
            end),
          },
      },
    },
  }
end)

return view

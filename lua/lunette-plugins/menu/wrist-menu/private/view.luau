-- The wrist menu's content: one button while closed, and a header with the registered actions while open.
local ui = require '@lunette-plugins/ui/react'
local menu = require '@lunette-contracts/menu'
local rows = require './rows'

local view = {}

export type Props = {
  read opened: ui.Store<boolean>,
  read snapshot: ui.Store<rows.Snapshot>,
  -- The closed button's edge, in metres.
  read size: number,
  read width: number,
  read height: number,
  read open: () -> (),
  read close: () -> (),
  read invoke: (menu.Descriptor) -> (),
}

view.Menu = ui.component('WristMenu', function(props: Props): ui.Child
  local c = ui.useComponents()
  local opened = ui.useStore(props.opened)
  local snapshot = ui.useStore(props.snapshot)
  if not opened then
    return c.Panel {
      width = props.size,
      height = props.size,
      padding = 'xs',
      c.Button { key = 'open', label = 'Menu', grow = 1, onActivate = props.open },
    }
  end
  local list = rows.rows(snapshot)
  return c.Panel {
    width = props.width,
    height = props.height,
    title = 'Menu',
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

-- The overlay panel's content: a header with the view switch and dismissal, a page of reports, and buttons that page
-- through them. Paging uses buttons rather than a scroll box so that focus traversal reaches every report.

local vocabulary = require '@lunette-contracts/vocabulary'
local ui = require '@lunette-plugins/ui/react'
local history = require './history'

local view = {}

-- 'new' shows reports since the last dismissal, and 'history' shows every report the history keeps.
export type Mode = 'new' | 'history'
export type State = { read mode: Mode, read page: number }

export type Actions = {
  read dismiss: () -> (),
  read setMode: (Mode) -> (),
  read setPage: (number) -> (),
}

export type Props = {
  read history: vocabulary.Store<history.History>,
  read state: vocabulary.Store<State>,
  read actions: Actions,
  read width: number,
  read lines: number,
  read pageSize: number,
}

local function plural(count: number, noun: string): string
  return `{count} {noun}{if count == 1 then '' else 's'}`
end

-- A report's card, keyed by its entry. The count reads as a multiplier and shows only for a repeated report.
local function card(c: any, entry: history.Entry, count: number, lines: number): ui.Child
  return c.Card {
    key = entry.id,
    c.Row {
      key = 'summary',
      gap = 'sm',
      align = 'start',
      c.Text {
        key = 'message',
        text = entry.message,
        style = 'label',
        maxLines = lines,
        grow = 1,
        shrink = 1,
        basis = 0,
      },
      if count > 1
        then c.Text { key = 'count', text = `×{count}`, style = 'value', color = 'danger', wrap = false }
        else nil,
    },
    if entry.traceback ~= ''
      then c.Text { key = 'traceback', text = entry.traceback, style = 'mono', color = 'muted', maxLines = lines }
      else nil,
  }
end

view.Overlay = ui.component('ErrorOverlay', function(props: Props): ui.Child
  local c = ui.useComponents()
  local record = ui.useStore(props.history)
  local state = ui.useStore(props.state)
  local actions = props.actions
  local unseen = history.unseen(record)
  local browsing = state.mode == 'history'
  local list = if browsing then record.entries else unseen
  local page = history.page(list, state.page, props.pageSize)
  return c.Panel {
    width = props.width,
    title = if browsing then 'Error history' else 'Errors',
    detail = if browsing then plural(page.total, 'report') else `{page.total} new`,
    c.HeaderActions {
      c.Button {
        key = 'mode',
        label = if browsing then 'New' else 'History',
        variant = 'band',
        disabledReason = if browsing and #unseen == 0 then 'No errors since the last dismissal.' else nil,
        onActivate = function(): ()
          actions.setMode(if browsing then 'new' else 'history')
        end,
      },
      c.Button { key = 'dismiss', label = 'Dismiss', variant = 'band', onActivate = actions.dismiss },
    },
    c.Body {
      key = 'body',
      gap = 'sm',
      if page.total == 0 then c.Text { key = 'empty', text = 'No errors reported.', color = 'muted' } else nil,
      c.Column {
        key = 'entries',
        gap = 'sm',
        ui.map(page.entries, function(entry: history.Entry): ui.Child
          return card(c, entry, if browsing then entry.count else entry.unseen, props.lines)
        end),
      },
      if page.pages > 1
        then c.Row {
          key = 'pages',
          gap = 'sm',
          align = 'center',
          c.Button {
            key = 'newer',
            label = 'Newer',
            disabledReason = if page.index == 1 then 'This page holds the newest reports.' else nil,
            onActivate = function(): ()
              actions.setPage(page.index - 1)
            end,
          },
          c.Text {
            key = 'position',
            text = `{page.first}–{page.last} of {page.total}`,
            style = 'caption',
            color = 'muted',
            align = 'center',
            grow = 1,
          },
          c.Button {
            key = 'older',
            label = 'Older',
            disabledReason = if page.index == page.pages then 'This page holds the oldest reports.' else nil,
            onActivate = function(): ()
              actions.setPage(page.index + 1)
            end,
          },
        }
        else nil,
    },
  }
end)

return view

-- The browser column: the view and filter toolbar, the search field, and either the entry list or the graph.

local ui = require '@lunette-plugins/ui/react'
local uiHost = require '@lunette-contracts/ui-host'
local controller = require '../composition/controller'
local view = require '../inspection/view'
local model = require './model'
local graphView = require './graph-view'

local browser = {}

local Search = ui.component('PluginSearch', function(): ui.Child
  local c = ui.useComponents()
  local m = model.use()
  local state = m.state
  local field = ui.useRef(nil :: uiHost.Node?)
  -- Opening the search focuses its field, which shows the shared keyboard, and closing it returns the keyboard.
  ui.useEffect(function(): (() -> ())?
    local node = field.current
    if node and not node.dead then
      m.focusField(node)
    end
    return m.releaseField
  end, { state.view.searchActive })
  return c.TextField {
    key = 'search-field',
    ref = field,
    value = state.view.query,
    placeholder = 'Search plugins',
    onChange = function(text: string): ()
      m.change(function(): ()
        controller.setSearch(state, text)
      end)
    end,
    onSubmit = function(text: string): ()
      m.change(function(): ()
        controller.setSearch(state, text)
        controller.endSearch(state)
      end)
    end,
    onCancel = function(_text: string): ()
      m.change(function(): ()
        controller.endSearch(state)
      end)
    end,
  }
end)

local Entries = ui.component('PluginEntries', function(): ui.Child
  local c = ui.useComponents()
  local m = model.use()
  local state = m.state
  local visible = view.visible(state.view)
  local items = {}
  for _, entry in state.entries do
    if visible[entry.instanceId] then
      items[#items + 1] = {
        id = entry.id,
        title = entry.id,
        detail = entry.state .. (if entry.protected then ', protected' else ''),
        trailing = if entry.enabled then nil else 'disabled',
      }
    end
  end
  local selected = controller.selected(state)
  return c.ScrollBox {
    key = 'entries-box',
    grow = 1,
    if #items == 0
      then c.Text { key = 'empty', text = 'No plugins match the current filter.', style = 'caption', color = 'muted' }
      else c.List {
        key = 'entries',
        items = items,
        value = if selected then selected.id else nil,
        onChange = function(id: string): ()
          m.change(function(): ()
            controller.selectEntry(state, id)
          end)
        end,
      },
  }
end)

browser.Browser = ui.component('PluginBrowser', function(): ui.Child
  local c = ui.useComponents()
  local m = model.use()
  local state = m.state
  local graphShown = state.presentation == 'graph'
  local mode = if state.view.mode == 'impact' then 'affected' else state.view.mode
  return c.Column {
    key = 'browser',
    grow = 1,
    shrink = 1,
    gap = 'sm',
    c.Row {
      key = 'toolbar',
      gap = 'sm',
      align = 'center',
      c.Segmented {
        key = 'view',
        options = model.options(m, { 'entries-view', 'graph-view' }),
        value = state.presentation .. '-view',
        onChange = m.invoke,
      },
      c.Spacer { key = 'spacer' },
      model.button(c, m, 'search'),
      model.button(c, m, 'clear-filter'),
      model.button(c, m, 'clear-selection'),
    },
    if state.view.searchActive then Search { key = 'search' } else nil,
    if graphShown
      then c.Row {
        key = 'camera',
        gap = 'sm',
        model.button(c, m, 'zoom-in', { grow = 1 }),
        model.button(c, m, 'zoom-out', { grow = 1 }),
        model.button(c, m, 'focus', { grow = 1 }),
        model.button(c, m, 'fit', { grow = 1 }),
      }
      else nil,
    c.Row {
      key = 'filters',
      gap = 'sm',
      align = 'center',
      c.Chip {
        key = 'transitive',
        label = 'Transitive',
        selected = state.view.transitive,
        onChange = function(_selected: boolean): ()
          m.invoke 'transitive'
        end,
      },
      c.Segmented {
        key = 'mode',
        options = model.options(m, { 'providers', 'consumers', 'all', 'affected' }),
        value = mode,
        onChange = m.invoke,
      },
    },
    if graphShown then graphView.Graph { key = 'graph' } else Entries { key = 'entries' },
  }
end)

return browser

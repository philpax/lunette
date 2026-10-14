-- Builds current manager actions without owning input devices or retaining UI handles.

local composition = require '@lunette-contracts/composition'
local graph = require '../inspection/graph'
local view = require '../inspection/view'
local editor = require './editor'
local toolbarLayout = require '../presentation/toolbar-layout'
local actions = {}

export type Edit = { operation: 'set' | 'add', path: editor.Path }
export type Action = { read run: () -> (), read editor: boolean }
export type Button = {
  read id: string,
  read label: string,
  read bounds: graph.Box,
  read enabled: boolean,
}
export type State = {
  view: view.State,
  service: composition.Service,
  width: number,
  height: number,
  presentation: 'entries' | 'graph',
  tab: 'inspect' | 'configure' | 'catalog',
  catalog: { read [number]: composition.KnownEntry },
  catalogSelection: string?,
  scroll: number,
  draft: editor.Model?,
  row: number?,
  edit: Edit?,
  text: string,
  message: string,
  editorRows: { read [number]: editor.Row },
}
export type TextActions = { read confirm: () -> (), read cancel: () -> (), read clear: () -> () }

function actions.cancelEdit(state: State): ()
  state.edit, state.text = nil, ''
end

function actions.change(state: State, nextModel: editor.Model?, problem: editor.Problem?): ()
  if nextModel then
    state.draft = nextModel
    state.message = 'Draft changed; Apply validates before replacing the activation.'
  elseif problem then
    state.message = problem.message
  end
end

function actions.build(
  state: State,
  layout: toolbarLayout.Layout,
  entry: composition.Entry?,
  textActions: TextActions
): ({ Button }, { [string]: Action })
  local buttons: { Button } = {}
  local bindings: { [string]: Action } = {}
  local function button(id: string, label: string, enabled: boolean, run: () -> (), editorAction: boolean?): ()
    local placement = layout.buttons[id]
    if not placement then
      return
    end
    buttons[#buttons + 1] = { id = id, label = label, bounds = placement.bounds, enabled = enabled }
    bindings[id] = { run = run, editor = editorAction == true }
  end
  button('entries-view', if state.presentation == 'entries' then 'Entries [shown]' else 'Entries', true, function()
    state.presentation = 'entries'
  end, true)
  button('graph-view', if state.presentation == 'graph' then 'Graph [shown]' else 'Graph', true, function()
    state.presentation = 'graph'
  end, true)
  for _, tab in { 'inspect', 'configure', 'catalog' } :: { 'inspect' | 'configure' | 'catalog' } do
    local enabled = tab ~= 'configure' or (entry ~= nil and entry.schema ~= nil)
    button(tab, tab:sub(1, 1):upper() .. tab:sub(2), enabled, function()
      if state.tab ~= tab then
        actions.cancelEdit(state)
      end
      state.tab, state.scroll = tab, 0
    end)
  end
  local id = if entry then entry.id else ''
  local mutable = entry ~= nil and not entry.protected
  button('enable', 'Enable', entry ~= nil and not entry.enabled, function()
    state.service:enable(id)
  end)
  button('disable', 'Disable', mutable and entry ~= nil and entry.enabled, function()
    state.service:disable(id)
  end)
  button('reload', 'Reload', mutable, function()
    state.service:reload(id)
  end)
  button('recover', 'Recover', mutable and entry ~= nil and entry.previousConfig ~= nil, function()
    state.service:recover(id)
    state.draft = nil
    actions.cancelEdit(state)
  end)
  button('remove', 'Remove', mutable, function()
    state.service:remove(id)
  end)
  button('apply', 'Apply', mutable and entry ~= nil and entry.schema ~= nil and state.draft ~= nil, function()
    local model = state.draft
    if model then
      state.service:configure(id, editor.draft(model))
      state.draft = nil
      actions.cancelEdit(state)
    end
  end)
  local row = if state.tab == 'configure' and state.row then state.editorRows[state.row] else nil
  button(
    'optional',
    if row and row.value ~= nil then 'Unset' else 'Set',
    row ~= nil and row.optional and row.canReset,
    function()
      if state.draft and row then
        actions.cancelEdit(state)
        actions.change(state, editor.set(state.draft, row.path, if row.value == nil then true else nil))
      end
    end,
    true
  )
  button('reset', 'Reset', row ~= nil and row.canReset, function()
    if state.draft and row then
      actions.cancelEdit(state)
      actions.change(state, editor.reset(state.draft, row.path))
    end
  end, true)
  local loadable = false
  for _, known in state.catalog do
    if known.id == state.catalogSelection and not known.installed then
      loadable = true
    end
  end
  button('load', 'Load', state.tab == 'catalog' and loadable, function()
    local selected = state.catalogSelection
    if selected then
      state.service:restore(selected)
    end
  end)
  button('add', 'Add', row ~= nil and row.canAdd, function()
    if state.draft and row then
      actions.cancelEdit(state)
      if row.control == 'map' then
        state.edit = { operation = 'add', path = row.path }
      else
        actions.change(state, editor.add(state.draft, row.path))
      end
    end
  end, true)
  button('remove-value', 'Remove value', row ~= nil and row.canRemove, function()
    if state.draft and row then
      actions.cancelEdit(state)
      actions.change(state, editor.remove(state.draft, row.path))
    end
  end, true)
  button('transitive', 'Transitive', true, function()
    state.view.transitive = not state.view.transitive
  end, true)
  for _, mode in { 'providers', 'consumers', 'all', 'impact' } do
    local actionId = if mode == 'impact' then 'affected' else mode
    local label = if mode == 'impact' then 'Affected' else mode:sub(1, 1):upper() .. mode:sub(2)
    button(actionId, label, true, function()
      state.view.mode = mode :: view.Mode
    end, true)
  end
  button('zoom-in', 'Zoom in', true, function()
    view.zoom(state.view, { x = state.view.viewport.x / 2, y = state.view.viewport.y / 2 }, 1.2)
  end, true)
  button('zoom-out', 'Zoom out', true, function()
    view.zoom(state.view, { x = state.view.viewport.x / 2, y = state.view.viewport.y / 2 }, 1 / 1.2)
  end, true)
  local selection = state.view.selection
  button('focus', 'Focus', selection ~= nil and selection.kind == 'node', function()
    view.focus(state.view)
  end, true)
  button('fit', 'Fit', true, function()
    view.endSearch(state.view)
    local bounds = toolbarLayout.compute(
      state.width,
      state.height,
      state.edit ~= nil,
      false,
      nil,
      state.presentation,
      state.tab
    ).graphBounds
    state.view.viewport = { x = bounds.width, y = bounds.height }
    view.reset(state.view)
  end, true)
  button('search', 'Search', true, function()
    view.search(state.view)
  end, true)
  button('clear-filter', 'Clear filter', true, function()
    view.setSearch(state.view, '')
    view.endSearch(state.view)
    state.view.mode = 'all'
  end, true)
  button('clear-selection', 'Clear selection', selection ~= nil, function()
    view.select(state.view, nil)
    state.view.mode = 'all'
  end, true)
  if state.edit then
    button('confirm', 'Confirm', true, textActions.confirm, true)
    button('cancel', 'Cancel', true, textActions.cancel, true)
    button('clear', 'Clear', true, textActions.clear, true)
  end
  return buttons, bindings
end

return actions

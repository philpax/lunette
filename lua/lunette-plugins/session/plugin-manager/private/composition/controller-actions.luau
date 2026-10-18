-- Builds the current manager actions, each with its enablement and the reason it is disabled, without owning input
-- devices or UI handles.

local composition = require '@lunette-contracts/composition'
local view = require '../inspection/view'
local editor = require './editor'
local actions = {}

export type Tab = 'inspect' | 'configure' | 'catalog' | 'saved'
export type Edit = { operation: 'set' | 'add', path: editor.Path }
export type Action = {
  read label: string,
  read reason: string?,
  read run: () -> (),
  read editor: boolean,
}
export type State = {
  view: view.State,
  service: composition.Service,
  presentation: 'entries' | 'graph',
  tab: Tab,
  catalog: { read [number]: composition.KnownEntry },
  catalogSelection: string?,
  -- Every saved field, and the one selected on the Saved tab.
  savedSettings: { read [number]: composition.SavedSetting },
  savedSelection: { read id: string, read field: string }?,
  draft: editor.Model?,
  row: number?,
  edit: Edit?,
  text: string,
  message: string,
  editorRows: { read [number]: editor.Row },
}
export type TextActions = { read confirm: () -> (), read cancel: () -> (), read clear: () -> () }

local NO_ENTRY = 'Select a plugin entry first.'
local PROTECTED = 'The entry is protected.'
local REQUIRED = 'A protected entry depends on this entry.'

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

-- The reason an entry action is unavailable, checked in order, or nil when it is available.
local function first(...: string | false): string?
  for index = 1, select('#', ...) do
    local reason = select(index, ...)
    if reason then
      return reason
    end
  end
  return nil
end

function actions.build(state: State, entry: composition.Entry?, textActions: TextActions): { [string]: Action }
  local bindings: { [string]: Action } = {}
  local function button(id: string, label: string, reason: string?, run: () -> (), editorAction: boolean?): ()
    bindings[id] = { label = label, reason = reason, run = run, editor = editorAction == true }
  end
  button('entries-view', 'Entries', nil, function()
    state.presentation = 'entries'
  end, true)
  button('graph-view', 'Graph', nil, function()
    state.presentation = 'graph'
  end, true)
  for _, tab in { 'inspect', 'configure', 'catalog', 'saved' } :: { Tab } do
    local reason = if tab ~= 'configure'
      then nil
      else first(entry == nil and NO_ENTRY, entry ~= nil and entry.schema == nil and 'The entry has no schema.')
    button(tab, tab:sub(1, 1):upper() .. tab:sub(2), reason, function()
      if state.tab ~= tab then
        actions.cancelEdit(state)
      end
      state.tab = tab
    end)
  end
  local id = if entry then entry.id else ''
  local protected = entry ~= nil and entry.protected and PROTECTED
  local required = protected or (entry ~= nil and entry.required and REQUIRED)
  button(
    'enable',
    'Enable',
    first(entry == nil and NO_ENTRY, entry ~= nil and entry.enabled and 'The entry is enabled.'),
    function()
      state.service:enable(id)
    end
  )
  button(
    'disable',
    'Disable',
    first(entry == nil and NO_ENTRY, required, entry ~= nil and not entry.enabled and 'The entry is disabled.'),
    function()
      state.service:disable(id)
    end
  )
  button('reload', 'Reload', first(entry == nil and NO_ENTRY, protected), function()
    state.service:reload(id)
  end)
  button(
    'recover',
    'Recover',
    first(
      entry == nil and NO_ENTRY,
      protected,
      entry ~= nil and entry.previousConfig == nil and 'No previous configuration is recorded.'
    ),
    function()
      state.service:recover(id)
      state.draft = nil
      actions.cancelEdit(state)
    end
  )
  button('remove', 'Remove', first(entry == nil and NO_ENTRY, required), function()
    state.service:remove(id)
  end)
  button(
    'apply',
    'Apply',
    first(
      entry == nil and NO_ENTRY,
      protected,
      entry ~= nil and entry.schema == nil and 'The entry has no schema.',
      state.draft == nil and 'Open Configure to edit a draft.'
    ),
    function()
      local model = state.draft
      if model then
        state.service:configure(id, editor.draft(model))
        state.draft = nil
        actions.cancelEdit(state)
      end
    end
  )
  local row = if state.tab == 'configure' and state.row then state.editorRows[state.row] else nil
  local noRow = row == nil and 'Select an option first.'
  button(
    'optional',
    if row and row.value ~= nil then 'Unset' else 'Set',
    first(noRow, row ~= nil and not (row.optional and row.canReset) and 'The option is not optional.'),
    function()
      if state.draft and row then
        actions.cancelEdit(state)
        actions.change(state, editor.set(state.draft, row.path, if row.value == nil then true else nil))
      end
    end,
    true
  )
  button(
    'reset',
    'Reset',
    first(noRow, row ~= nil and not row.canReset and (row.reason or 'The option has no default.')),
    function()
      if state.draft and row then
        actions.cancelEdit(state)
        actions.change(state, editor.reset(state.draft, row.path))
      end
    end,
    true
  )
  -- A saved field belongs to the option at the top of its path.
  local savedField = row and #row.path == 1 and type(row.path[1]) == 'string' and row.path[1] :: string or nil
  local saved = entry and entry.saved
  local hasSaved = false
  for _ in saved or {} do
    hasSaved = true
  end
  button(
    'forget-saved',
    'Forget saved',
    first(noRow, not (savedField and saved and saved[savedField] ~= nil) and 'The option has no saved value.'),
    function()
      if savedField then
        state.service:forgetSaved(id, savedField)
        state.draft = nil
        actions.cancelEdit(state)
      end
    end
  )
  button(
    'forget-entry',
    'Forget all saved',
    first(entry == nil and NO_ENTRY, not hasSaved and 'The entry has no saved settings.'),
    function()
      state.service:forgetSaved(id)
      state.draft = nil
      actions.cancelEdit(state)
    end
  )
  local chosen = state.savedSelection
  button('forget-selected', 'Forget', if chosen then nil else 'Select a saved setting first.', function()
    if chosen then
      state.service:forgetSaved(chosen.id, chosen.field)
      state.savedSelection = nil
    end
  end)
  button(
    'forget-everything',
    'Forget everything',
    if #state.savedSettings > 0 then nil else 'No settings are saved.',
    function()
      local ids: { [string]: boolean } = {}
      for _, setting in state.savedSettings do
        ids[setting.id] = true
      end
      for savedId in ids do
        state.service:forgetSaved(savedId)
      end
      state.savedSelection = nil
    end
  )
  local loadable = false
  for _, known in state.catalog do
    if known.id == state.catalogSelection and not known.installed then
      loadable = true
    end
  end
  button('load', 'Load', if loadable then nil else 'Select a removed entry first.', function()
    local selected = state.catalogSelection
    if selected then
      state.service:restore(selected)
    end
  end)
  button(
    'add',
    'Add',
    first(noRow, row ~= nil and not row.canAdd and 'The option is not a collection that can grow.'),
    function()
      if state.draft and row then
        actions.cancelEdit(state)
        if row.control == 'map' then
          state.edit = { operation = 'add', path = row.path }
        else
          actions.change(state, editor.add(state.draft, row.path))
        end
      end
    end,
    true
  )
  button(
    'remove-value',
    'Remove value',
    first(noRow, row ~= nil and not row.canRemove and 'The option is not a removable collection entry.'),
    function()
      if state.draft and row then
        actions.cancelEdit(state)
        actions.change(state, editor.remove(state.draft, row.path))
      end
    end,
    true
  )
  button('transitive', 'Transitive', nil, function()
    state.view.transitive = not state.view.transitive
  end, true)
  for _, mode in { 'providers', 'consumers', 'all', 'impact' } :: { view.Mode } do
    local actionId = if mode == 'impact' then 'affected' else mode
    local label = if mode == 'impact' then 'Affected' else mode:sub(1, 1):upper() .. mode:sub(2)
    button(actionId, label, nil, function()
      state.view.mode = mode
    end, true)
  end
  local function centre(): { x: number, y: number }
    return { x = state.view.viewport.x / 2, y = state.view.viewport.y / 2 }
  end
  button('zoom-in', 'Zoom in', nil, function()
    view.zoom(state.view, centre(), 1.2)
  end, true)
  button('zoom-out', 'Zoom out', nil, function()
    view.zoom(state.view, centre(), 1 / 1.2)
  end, true)
  local selection = state.view.selection
  button(
    'focus',
    'Focus',
    if selection ~= nil and selection.kind == 'node' then nil else 'Select a plugin first.',
    function()
      view.focus(state.view)
    end,
    true
  )
  button('fit', 'Fit', nil, function()
    view.reset(state.view)
  end, true)
  button('search', 'Search', nil, function()
    view.search(state.view)
  end, true)
  button('clear-filter', 'Clear filter', nil, function()
    view.setSearch(state.view, '')
    view.endSearch(state.view)
    state.view.mode = 'all'
  end, true)
  button('clear-selection', 'Clear selection', if selection ~= nil then nil else 'Nothing is selected.', function()
    view.select(state.view, nil)
    state.view.mode = 'all'
  end, true)
  if state.edit then
    button('confirm', 'Confirm', nil, textActions.confirm, true)
    button('cancel', 'Cancel', nil, textActions.cancel, true)
    button('clear', 'Clear', nil, textActions.clear, true)
  end
  return bindings
end

return actions

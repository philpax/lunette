-- Captures only the render inputs of idle Configure in the unfiltered entry list. Other manager states always publish.

local composition = require '@lunette-contracts/composition'
local view = require '../inspection/view'
local actions = require './controller-actions'
local editor = require './editor'
local publication = {}

type EntryRow = {
  id: string,
  instanceId: string,
  state: string,
  protected: boolean,
  required: boolean,
  enabled: boolean,
}
type OptionRow = {
  path: editor.Path,
  label: string,
  readOnly: boolean,
  reason: string?,
  description: string?,
  text: string,
  saved: boolean,
  baseText: string?,
}
type Action = { label: string, reason: string? }
export type Snapshot = {
  entries: { EntryRow },
  selectedId: string,
  selectedName: string,
  status: string,
  transitive: boolean,
  rows: { OptionRow },
  actions: { [string]: Action },
}
export type State = actions.State & {
  read entries: { composition.Entry },
  read actions: { [string]: actions.Action },
}

function publication.capture(
  state: State,
  entry: composition.Entry?,
  status: string,
  valueText: (unknown) -> string
): Snapshot?
  if
    state.presentation ~= 'entries'
    or state.view.mode ~= 'all'
    or state.view.query ~= ''
    or state.view.searchActive ~= false
    or state.tab ~= 'configure'
    or state.draft == nil
    or entry == nil
    or state.row ~= nil
    or state.edit ~= nil
  then
    return nil
  end
  local entries: { EntryRow } = {}
  -- Entries and the graph are separate service reads; use the same membership as the rendered entry list.
  local visible = view.visible(state.view)
  for _, current in state.entries do
    if visible[current.instanceId] then
      entries[#entries + 1] = {
        id = current.id,
        instanceId = current.instanceId,
        state = current.state,
        protected = current.protected,
        required = current.required,
        enabled = current.enabled,
      }
    end
  end
  local rows: { OptionRow } = {}
  local saved = entry.saved
  local base = (if type(entry.baseConfig) == 'table' then entry.baseConfig else {}) :: { [string]: unknown }
  for _, row in state.editorRows do
    local field = if #row.path == 1 then row.path[1] else nil
    local isSaved = type(field) == 'string' and saved ~= nil and saved[field] ~= nil
    rows[#rows + 1] = {
      path = table.clone(row.path),
      label = row.label,
      readOnly = row.readOnly,
      reason = row.reason,
      description = row.description,
      text = row.text,
      saved = isSaved,
      baseText = if isSaved then valueText(base[field :: string]) else nil,
    }
  end
  local bindings: { [string]: Action } = {}
  for id, action in state.actions do
    bindings[id] = { label = action.label, reason = action.reason }
  end
  return {
    entries = entries,
    selectedId = entry.id,
    selectedName = entry.name,
    status = status,
    transitive = state.view.transitive,
    rows = rows,
    actions = bindings,
  }
end

function publication.changed(before: Snapshot?, after: Snapshot?): boolean
  if not before or not after then
    return true
  end
  if
    before.selectedId ~= after.selectedId
    or before.selectedName ~= after.selectedName
    or before.status ~= after.status
    or before.transitive ~= after.transitive
    or #before.entries ~= #after.entries
    or #before.rows ~= #after.rows
  then
    return true
  end
  for index, entry in before.entries do
    local other = after.entries[index]
    if
      entry.id ~= other.id
      or entry.instanceId ~= other.instanceId
      or entry.state ~= other.state
      or entry.protected ~= other.protected
      or entry.required ~= other.required
      or entry.enabled ~= other.enabled
    then
      return true
    end
  end
  for index, row in before.rows do
    local other = after.rows[index]
    if
      row.label ~= other.label
      or row.readOnly ~= other.readOnly
      or row.reason ~= other.reason
      or row.description ~= other.description
      or row.text ~= other.text
      or row.saved ~= other.saved
      or row.baseText ~= other.baseText
      or #row.path ~= #other.path
    then
      return true
    end
    for part, value in row.path do
      if value ~= other.path[part] then
        return true
      end
    end
  end
  -- Runs are deliberately excluded: invocation resolves the freshly rebuilt map against the mutable controller state.
  for id, action in before.actions do
    local other = after.actions[id]
    if not other or action.label ~= other.label or action.reason ~= other.reason then
      return true
    end
  end
  for id in after.actions do
    if not before.actions[id] then
      return true
    end
  end
  return false
end

return publication

-- Owns manager domain transitions, schema drafts, graph gestures, and session composition actions. Graph positions
-- are canvas pixels from the canvas's top-left corner.

local composition = require '@lunette-contracts/composition'
local graph = require '../inspection/graph'
local view = require '../inspection/view'
local projection = require '../inspection/projection'
local details = require '../inspection/details'
local brokers = require '../inspection/brokers'
local editor = require './editor'
local controllerActions = require './controller-actions'
local controller = {}

export type Path = editor.Path
export type Tab = controllerActions.Tab
export type Button = controllerActions.Button
type Registration = typeof(require('@lunette-contracts/inspection').snapshot({}).registrations[1])

export type State = controllerActions.State & {
  projected: projection.Projected,
  entries: { composition.Entry },
  readers: { brokers.Reader },
  draftEntry: string?,
  buttons: { Button },
  actions: { [string]: controllerActions.Action },
  details: { string },
  -- Whether the camera has been fitted to a measured canvas.
  fitted: boolean,
}

-- A request to confirm an action that unloads plugins.
export type Confirmation = {
  read action: string,
  read entry: string,
  read title: string,
  read body: string,
  read confirm: string,
}

local refresh: (State) -> ()
local selectedEntry: (State) -> composition.Entry?
local cancelEdit = controllerActions.cancelEdit

function controller.new(service: composition.Service, readers: { brokers.Reader }): State
  local state: State = {
    view = view.new { x = 1, y = 1 },
    service = service,
    projected = projection.snapshot(service:snapshot()),
    entries = {},
    readers = readers,
    presentation = 'entries',
    tab = 'inspect',
    catalog = {},
    catalogSelection = nil,
    savedSettings = {},
    savedSelection = nil,
    draft = nil,
    draftEntry = nil,
    row = nil,
    edit = nil,
    text = '',
    message = '',
    buttons = {},
    actions = {},
    editorRows = {},
    details = {},
    fitted = false,
  }
  refresh(state)
  return state
end

function controller.update(state: State): ()
  refresh(state)
end

function controller.button(state: State, id: string): Button?
  for _, button in state.buttons do
    if button.id == id then
      return button
    end
  end
  return nil
end

function controller.selected(state: State): composition.Entry?
  return selectedEntry(state)
end

-- The status line: the edit or search in progress, or the last message.
function controller.status(state: State): string
  if state.edit then
    return 'Editing: ' .. state.text
  elseif state.view.searchActive then
    return 'Search: ' .. state.view.query
  end
  return state.message
end

function controller.invoke(state: State, id: string): boolean
  refresh(state)
  local button = controller.button(state, id)
  if not button or not button.enabled then
    return false
  end
  local action = state.actions[id]
  local ok, problem = pcall(action.run)
  if not ok then
    state.message = tostring(problem)
  elseif not action.editor then
    state.message = 'Action completed; state and diagnostics appear in the inspector.'
  end
  refresh(state)
  return ok
end

local VERBS: { [string]: { title: string, effect: string } } = {
  disable = { title = 'Disable', effect = 'stops until it is enabled again' },
  reload = { title = 'Reload', effect = 'restarts with its current configuration' },
  remove = { title = 'Remove', effect = 'unloads, and Catalog can load it again' },
}
local NAMED_LIMIT = 8

-- The confirmation an action needs, or nil when it runs directly. Actions that unload the selected entry name the
-- plugins they also unload.
function controller.confirmation(state: State, id: string): Confirmation?
  local verb = VERBS[id]
  local entry = selectedEntry(state)
  local button = controller.button(state, id)
  if not verb or not entry or not button or not button.enabled then
    return nil
  end
  local affected = graph.impact(state.projected.graph, entry.instanceId)
  local names: { string } = {}
  for index, instanceId in affected do
    if index > NAMED_LIMIT then
      names[#names + 1] = `and {#affected - NAMED_LIMIT} more`
      break
    end
    local instance = state.projected.instances[instanceId]
    names[#names + 1] = if instance then instance.name else '#' .. instanceId
  end
  local body = `{entry.id} {verb.effect}.`
  if #affected > 0 then
    body ..= ` This also unloads {#affected} dependent or owned plugin{if #affected == 1 then '' else 's'}: ` .. table.concat(
      names,
      ', '
    ) .. '.'
  end
  return table.freeze {
    action = id,
    entry = entry.id,
    title = `{verb.title} {entry.id}?`,
    body = body,
    confirm = verb.title,
  }
end

function controller.select(state: State, selection: graph.Selection?): ()
  view.select(state.view, selection)
  refresh(state)
end

-- Selects the entry's instance, as choosing it in the entry list does.
function controller.selectEntry(state: State, id: string): ()
  for _, entry in state.entries do
    if entry.id == id then
      controller.select(state, { kind = 'node', id = entry.instanceId })
      return
    end
  end
end

function controller.setSearch(state: State, value: string): ()
  view.setSearch(state.view, value)
  refresh(state)
end

function controller.endSearch(state: State): ()
  view.endSearch(state.view)
  refresh(state)
end

function controller.setText(state: State, value: string): ()
  if state.edit then
    local message = editor.textProblem(value)
    if message then
      state.message = message
      return
    end
    state.text = value
  end
end

function controller.confirmText(state: State): boolean
  local model, edit = state.draft, state.edit
  if not model or not edit then
    return false
  end
  local nextModel, problem
  if edit.operation == 'add' then
    nextModel, problem = editor.add(model, edit.path, state.text)
  else
    nextModel, problem = editor.setText(model, edit.path, state.text)
  end
  controllerActions.change(state, nextModel, problem)
  if nextModel then
    cancelEdit(state)
    state.row = nil
  end
  refresh(state)
  return nextModel ~= nil
end

-- Ending an edit deselects its row, so selecting the row again restarts the edit.
function controller.cancelText(state: State): ()
  cancelEdit(state)
  state.row = nil
  refresh(state)
end

function controller.clearText(state: State): ()
  controller.setText(state, '')
end

-- Selecting an editable text row starts its edit; boolean and choice rows show their value field instead.
function controller.selectRow(state: State, index: number): ()
  local row = if state.tab == 'configure' then state.editorRows[index] else nil
  if not row then
    return
  end
  if state.row ~= index then
    cancelEdit(state)
  end
  state.row = index
  if row.readOnly then
    state.message = row.reason or 'This value is read-only.'
  elseif row.control == 'number' or row.control == 'string' then
    if not state.edit then
      state.text = row.text
      state.edit = { operation = 'set', path = row.path }
      state.message = if row.escaped then 'Editing escaped bytes: use \\\\, \\n, \\r, \\t, or \\xHH.' else ''
    end
  elseif row.control ~= 'boolean' and row.control ~= 'choice' then
    state.message = row.description or 'Select a child option, or use Add, Remove, and Reset.'
  end
  refresh(state)
end

function controller.toggle(state: State): ()
  local row = if state.tab == 'configure' and state.row then state.editorRows[state.row] else nil
  local model = state.draft
  if model and row and row.control == 'boolean' and not row.readOnly then
    cancelEdit(state)
    controllerActions.change(state, editor.toggle(model, row.path))
  end
  refresh(state)
end

function controller.choose(state: State, index: number, choiceIndex: number): ()
  local row = if state.tab == 'configure' then state.editorRows[index] else nil
  local model = state.draft
  if not model or not row or row.readOnly or not row.choices then
    return
  end
  if choiceIndex % 1 ~= 0 or choiceIndex < 1 or choiceIndex > #row.choices then
    return
  end
  cancelEdit(state)
  state.row = index
  controllerActions.change(state, editor.set(model, row.path, row.choices[choiceIndex]))
  refresh(state)
end

function controller.selectSaved(state: State, id: string, field: string): ()
  state.savedSelection = { id = id, field = field }
  refresh(state)
end

-- A configuration value as the Configure and Saved tabs show it.
function controller.valueText(value: unknown): string
  local kind = type(value)
  if kind == 'string' then
    return string.format('%q', value :: string)
  elseif kind == 'number' then
    return string.format('%.4g', value :: number)
  elseif kind == 'vector' then
    local v = value :: vector
    return string.format('(%.3g, %.3g, %.3g)', v.x, v.y, v.z)
  elseif kind == 'table' then
    local parts: { string } = {}
    for index, item in value :: { unknown } do
      if index > 4 then
        parts[#parts + 1] = '...'
        break
      end
      parts[#parts + 1] = controller.valueText(item)
    end
    return '{ ' .. table.concat(parts, ', ') .. ' }'
  elseif value == nil then
    return 'not set'
  end
  return tostring(value)
end

function controller.selectCatalog(state: State, id: string): ()
  for index, known in state.catalog do
    if known.id == id then
      if state.catalogSelection ~= id then
        cancelEdit(state)
      end
      state.catalogSelection = id
      state.row = index
      refresh(state)
      return
    end
  end
end

-- Records the canvas size, and fits the camera to the graph the first time the canvas has a size. Answers whether
-- the size changed.
function controller.resize(state: State, width: number, height: number): boolean
  if not (width > 0 and height > 0 and width < math.huge and height < math.huge) then
    return false
  end
  local viewport = state.view.viewport
  if viewport.x == width and viewport.y == height then
    return false
  end
  state.view.viewport = { x = width, y = height }
  if not state.fitted then
    state.fitted = true
    state.view.camera = graph.fit(state.view.layout, state.view.viewport)
  end
  return true
end

function controller.graphPress(state: State, point: graph.Point): ()
  view.press(state.view, point)
end

function controller.graphMove(state: State, point: graph.Point): ()
  view.move(state.view, point)
end

-- A release inside the canvas completes a click or a drag; one outside it keeps the pan and selects nothing.
function controller.graphRelease(state: State, point: graph.Point, inside: boolean): ()
  if inside then
    view.release(state.view, point)
  else
    view.move(state.view, point)
    view.cancel(state.view)
  end
  refresh(state)
end

function controller.graphCancel(state: State): ()
  view.cancel(state.view)
end

-- Zooms about a point in the canvas, or about its centre when no point is given.
function controller.graphZoom(state: State, factor: number, point: graph.Point?): ()
  if factor > 0 and factor < math.huge then
    view.zoom(state.view, point or { x = state.view.viewport.x / 2, y = state.view.viewport.y / 2 }, factor)
  end
end

selectedEntry = function(state: State): composition.Entry?
  local selection = state.view.selection
  return if selection and selection.kind == 'node' then details.entry(state.entries, selection.id) else nil
end

refresh = function(state: State): ()
  state.projected = projection.snapshot(state.service:snapshot())
  state.entries = state.service:entries()
  state.catalog = state.service:catalog()
  state.savedSettings = state.service:savedSettings()
  local chosen = state.savedSelection
  if chosen then
    local present = false
    for _, setting in state.savedSettings do
      present = present or (setting.id == chosen.id and setting.field == chosen.field)
    end
    if not present then
      state.savedSelection = nil
    end
  end
  view.update(state.view, state.projected.graph)
  local entry = selectedEntry(state)
  if not entry or (state.draftEntry and state.draftEntry ~= entry.id) then
    state.draft, state.draftEntry, state.row = nil, nil, nil
    cancelEdit(state)
  end
  if state.tab == 'configure' and entry and entry.schema and not state.draft then
    state.draft = editor.new(entry.schema, entry.config)
    state.draftEntry = entry.id
    state.row = nil
    cancelEdit(state)
  end
  local draft = state.draft
  state.editorRows = if draft then editor.rows(draft) else {}
  if state.tab == 'catalog' then
    state.details = { 'Known session entries', 'Select a removed entry, then Load.' }
  elseif state.tab == 'saved' then
    state.details = {
      'Saved settings',
      'Settings changed in a session, which take precedence over main.luau. Forget returns a setting to main.luau.',
    }
  elseif state.tab == 'configure' and entry and entry.schema then
    state.details = { entry.id .. ': configuration draft', 'Callbacks and opaque values remain read-only.' }
    if state.message == '' then
      state.message = tostring(#state.editorRows) .. ' options.'
    end
  else
    state.details = details.lines(
      state.projected,
      state.view.selection,
      state.entries,
      brokers.snapshot(state.readers),
      function(registration: Registration): string?
        return state.service:ownerId(registration.owner)
      end
    )
  end
  state.buttons, state.actions = controllerActions.build(state, entry, {
    confirm = function(): ()
      controller.confirmText(state)
    end,
    cancel = function(): ()
      controller.cancelText(state)
    end,
    clear = function(): ()
      controller.clearText(state)
    end,
  })
end

return controller

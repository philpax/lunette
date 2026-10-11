-- Owns manager domain transitions, schema drafts, and session composition actions.

local composition = require '@lunette-contracts/composition'
local graph = require './graph'
local view = require './view'
local projection = require './projection'
local details = require './details'
local brokers = require './brokers'
local draw = require './draw'
local editor = require './editor'
local toolbarLayout = require './toolbar-layout'
local controllerActions = require './controller-actions'
local controller = {}
type Registration = typeof(require('@lunette-contracts/inspection').snapshot({}).registrations[1])

export type State = controllerActions.State & {
  projected: projection.Projected,
  entries: { composition.Entry },
  readers: { brokers.Reader },
  sidebar: number,
  layout: toolbarLayout.Layout,
  draftEntry: string?,
  buttons: { controllerActions.Button },
  actions: { [string]: controllerActions.Action },
  lines: { string },
  detailRecords: { string },
  measuredRecords: { string }?,
  measuredDetails: { string }?,
  wrappedDetails: boolean,
}

local refresh: (State) -> ()
local selectedEntry: (State) -> composition.Entry?
local showDetails: (State, { string }) -> ()
local localPoint: (State, graph.Point) -> graph.Point
local cancelEdit = controllerActions.cancelEdit

function controller.new(service: composition.Service, readers: { brokers.Reader }, width: number, height: number): State
  local layout = toolbarLayout.compute(width, height, false, false, nil, 'entries', 'inspect')
  local state: State = {
    view = view.new { x = layout.graphBounds.width, y = layout.graphBounds.height },
    service = service,
    projected = projection.snapshot(service:snapshot()),
    entries = {},
    readers = readers,
    width = width,
    height = height,
    presentation = 'entries',
    sidebar = toolbarLayout.sidebarWidth(width),
    tab = 'inspect',
    catalog = {},
    catalogSelection = nil,
    layout = layout,
    scroll = 0,
    draft = nil,
    draftEntry = nil,
    row = nil,
    edit = nil,
    text = '',
    message = '',
    buttons = {},
    actions = {},
    editorRows = {},
    lines = {},
    detailRecords = {},
    measuredRecords = nil,
    measuredDetails = nil,
    wrappedDetails = false,
  }
  refresh(state)
  return state
end

function controller.update(state: State): ()
  refresh(state)
end

-- Rows and the catalog are lists; the details text is wrapped only while neither is shown.
function controller.listed(state: State): boolean
  return state.tab == 'catalog' or (state.tab == 'configure' and state.draft ~= nil)
end

function controller.measureDetails(state: State, font: Font, size: number): ()
  if controller.listed(state) then
    return
  end
  local all = draw.wrapDetails(font, state.detailRecords, state.sidebar, size)
  state.measuredRecords, state.measuredDetails = state.detailRecords, all
  showDetails(state, all)
  state.wrappedDetails = true
end

function controller.options(state: State): draw.Options
  return {
    width = state.width,
    height = state.height,
    sidebar = state.sidebar,
    detailsTop = state.layout.detailsTop,
    details = state.lines,
    wrappedDetails = state.wrappedDetails,
    body = if controller.listed(state) then state.layout.bodyBounds else nil,
    footer = if state.edit
      then 'Editing: ' .. state.text
      else if state.view.searchActive then 'Search: ' .. state.view.query else state.message,
  }
end

function controller.invoke(state: State, id: string): boolean
  refresh(state)
  for _, button in state.buttons do
    if button.id == id and button.enabled then
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
  end
  return false
end

function controller.setSearch(state: State, value: string): ()
  view.setSearch(state.view, value)
  refresh(state)
end

function controller.endSearch(state: State, refreshDetails: boolean?): ()
  view.endSearch(state.view)
  if refreshDetails ~= false then
    refresh(state)
  end
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
function controller.cancelText(state: State, refreshDetails: boolean?): ()
  cancelEdit(state)
  state.row = nil
  if refreshDetails ~= false then
    refresh(state)
  end
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

function controller.scrollBy(state: State, rows: number): ()
  if rows == rows and math.abs(rows) < math.huge then
    state.scroll = math.max(0, state.scroll + math.floor(rows))
    refresh(state)
  end
end

function controller.graphPress(state: State, point: graph.Point): ()
  local bounds = state.layout.graphBounds
  if
    point.x >= bounds.x
    and point.x < bounds.x + bounds.width
    and point.y >= bounds.y
    and point.y < bounds.y + bounds.height
  then
    view.press(state.view, localPoint(state, point))
  end
end

function controller.graphMove(state: State, point: graph.Point): ()
  view.move(state.view, localPoint(state, point))
end

function controller.graphRelease(state: State, point: graph.Point, published: view.State?): ()
  local previous = state.view.selection
  local gesture = state.view.dragging
  if published and gesture and gesture.kind == 'pending-click' then
    local target = table.clone(published)
    target.dragging = gesture
    view.release(target, localPoint(state, point))
    if state.view.dragging == gesture then
      state.view.selection = target.selection
      state.view.dragging = nil
    end
  else
    view.release(state.view, localPoint(state, point))
  end
  local selection = state.view.selection
  if
    (previous == nil) ~= (selection == nil)
    or (previous and selection and (previous.id ~= selection.id or previous.kind ~= selection.kind))
  then
    state.scroll = 0
  end
  refresh(state)
end

function controller.graphCancel(state: State): ()
  view.cancel(state.view)
end

function controller.graphZoom(state: State, point: graph.Point, factor: number): ()
  view.zoom(state.view, localPoint(state, point), factor)
end

selectedEntry = function(state: State): composition.Entry?
  local selection = state.view.selection
  return if selection and selection.kind == 'node' then details.entry(state.entries, selection.id) else nil
end

localPoint = function(state: State, point: graph.Point): graph.Point
  return { x = point.x - state.layout.graphBounds.x, y = point.y - state.layout.graphBounds.y }
end

showDetails = function(state: State, all: { string }): ()
  state.scroll = math.clamp(state.scroll, 0, math.max(0, #all - 1))
  state.lines = table.move(all, state.scroll + 1, #all, 1, {})
end

refresh = function(state: State): ()
  state.projected = projection.snapshot(state.service:snapshot())
  state.entries = state.service:entries()
  state.catalog = state.service:catalog()
  -- The graph viewport does not depend on the sidebar, so it is settled before the selection is.
  local graphBounds = toolbarLayout.compute(
    state.width,
    state.height,
    false,
    state.view.searchActive,
    nil,
    state.presentation,
    state.tab
  ).graphBounds
  state.view.viewport = { x = graphBounds.width, y = graphBounds.height }
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
  state.wrappedDetails = false
  local selectedRow = if state.tab == 'configure' and state.row then state.editorRows[state.row] else nil
  local valueField: ('boolean' | 'choice')? = nil
  if selectedRow and not selectedRow.readOnly then
    if selectedRow.control == 'boolean' or selectedRow.control == 'choice' then
      valueField = selectedRow.control
    end
  end
  state.layout = toolbarLayout.compute(
    state.width,
    state.height,
    state.edit ~= nil,
    state.view.searchActive,
    valueField,
    state.presentation,
    state.tab
  )
  if state.tab == 'catalog' then
    showDetails(state, { 'Known session entries', 'Select a removed entry, then Load.' })
  elseif state.tab == 'configure' and entry and entry.schema then
    showDetails(state, { entry.id .. ': configuration draft', 'Callbacks and opaque values remain read-only.' })
    if state.message == '' then
      state.message = tostring(#state.editorRows) .. ' options.'
    end
  else
    local all = details.lines(
      state.projected,
      state.view.selection,
      state.entries,
      brokers.snapshot(state.readers),
      function(registration: Registration): string?
        return state.service:ownerId(registration.owner)
      end
    )
    local previous = state.detailRecords
    local unchanged = #previous == #all
    for index, record in all do
      if previous[index] ~= record then
        unchanged = false
        break
      end
    end
    if unchanged then
      all = previous
    end
    state.detailRecords = all
    if state.measuredRecords == all and state.measuredDetails then
      all = state.measuredDetails
      state.wrappedDetails = true
    end
    showDetails(state, all)
  end
  state.buttons, state.actions = controllerActions.build(state, state.layout, entry, {
    confirm = function()
      controller.confirmText(state)
    end,
    cancel = function()
      controller.cancelText(state)
    end,
    clear = function()
      controller.clearText(state)
    end,
  })
end

return controller

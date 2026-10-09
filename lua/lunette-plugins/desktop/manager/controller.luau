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

export type State = controllerActions.State & {
  projected: projection.Projected,
  entries: { composition.Entry },
  readers: { brokers.Reader },
  sidebar: number,
  bodyTop: number,
  graphBounds: graph.Box,
  bodyBounds: graph.Box,
  editBounds: graph.Box?,
  searchBounds: graph.Box?,
  draftEntry: string?,
  buttons: { controllerActions.Button },
  actions: { [string]: controllerActions.Action },
  rows: { draw.Row },
  rowIndices: { number },
  lines: { string },
  detailRecords: { string },
  measuredRecords: { string }?,
  measuredDetails: { string }?,
  rowHeight: number,
  rowSpacing: number,
  wrappedDetails: boolean,
  wrapDetails: (({ string }, number) -> { string })?,
}

local refresh: (State) -> ()
local refreshRows: (State) -> ()
local selectedEntry: (State) -> composition.Entry?
local cancelEdit: (State) -> ()
local localPoint: (State, graph.Point) -> graph.Point

function controller.new(
  service: composition.Service,
  readers: { brokers.Reader },
  width: number,
  height: number,
  wrapDetails: (({ string }, number) -> { string })?,
  close: (() -> ())?
): State
  local layout = toolbarLayout.compute(width, height, false, false)
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
    bodyTop = layout.detailsTop,
    graphBounds = layout.graphBounds,
    bodyBounds = layout.bodyBounds,
    editBounds = nil,
    searchBounds = nil,
    scroll = 0,
    draft = nil,
    draftEntry = nil,
    row = nil,
    edit = nil,
    text = '',
    message = '',
    buttons = {},
    actions = {},
    rows = {},
    rowIndices = {},
    editorRows = {},
    lines = {},
    detailRecords = {},
    measuredRecords = nil,
    measuredDetails = nil,
    rowHeight = 34,
    rowSpacing = 2,
    wrappedDetails = false,
    wrapDetails = wrapDetails,
    close = close,
  }
  refresh(state)
  return state
end

function controller.update(state: State): ()
  refresh(state)
end

function controller.prepareStyle(
  state: State,
  rowHeight: number,
  rowSpacing: number,
  wrapDetails: (({ string }, number) -> { string })?
): () -> ()
  local prepared = table.clone(state)
  prepared.rowHeight, prepared.rowSpacing = rowHeight, rowSpacing
  if wrapDetails and state.wrappedDetails then
    local all = wrapDetails(state.detailRecords, state.sidebar)
    prepared.scroll = math.clamp(state.scroll, 0, math.max(0, #all - 1))
    prepared.lines = {}
    for index = prepared.scroll + 1, #all do
      prepared.lines[#prepared.lines + 1] = all[index]
    end
  end
  if rowHeight ~= state.rowHeight or rowSpacing ~= state.rowSpacing then
    refreshRows(prepared)
  end
  return function(): ()
    state.rowHeight, state.rowSpacing = prepared.rowHeight, prepared.rowSpacing
    state.scroll, state.lines = prepared.scroll, prepared.lines
    state.rows, state.rowIndices = prepared.rows, prepared.rowIndices
  end
end

function controller.measureDetails(state: State, font: Font, size: number): ()
  if state.tab == 'catalog' or (state.tab == 'configure' and state.draft) then
    return
  end
  local records = state.detailRecords
  local all = draw.wrapDetails(font, records, state.sidebar, size)
  if state.detailRecords ~= records then
    return
  end
  state.measuredRecords, state.measuredDetails = records, all
  state.scroll = math.clamp(state.scroll, 0, math.max(0, #all - 1))
  state.lines = {}
  for index = state.scroll + 1, #all do
    state.lines[#state.lines + 1] = all[index]
  end
  state.wrappedDetails = true
end

function controller.options(state: State): draw.Options
  return {
    width = state.width,
    height = state.height,
    sidebar = state.sidebar,
    detailsTop = state.bodyTop,
    details = state.lines,
    wrappedDetails = state.wrappedDetails,
    buttons = state.buttons,
    rows = state.rows,
    graphBounds = state.graphBounds,
    bodyBounds = state.bodyBounds,
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
  end
  refresh(state)
  return nextModel ~= nil
end

function controller.cancelText(state: State, refreshDetails: boolean?): ()
  cancelEdit(state)
  if refreshDetails ~= false then
    refresh(state)
  end
end

function controller.clearText(state: State): ()
  controller.setText(state, '')
end

function controller.selectRow(state: State, index: number, activate: boolean?): ()
  if state.tab == 'catalog' then
    local known = state.catalog[index]
    if known then
      controller.selectCatalog(state, known.id)
    end
    return
  end
  local row = if state.tab == 'configure' then state.editorRows[index] else nil
  if not row then
    return
  end
  if state.row ~= index then
    cancelEdit(state)
  end
  state.row = index
  local model = state.draft
  if activate and model then
    if row.readOnly then
      state.message = row.reason or 'This value is read-only.'
    elseif row.control == 'boolean' then
      cancelEdit(state)
      controllerActions.change(state, editor.toggle(model, row.path))
    elseif row.control == 'number' or row.control == 'string' then
      if not state.edit then
        state.text = row.text
        state.edit = { operation = 'set', path = row.path }
        state.message = if row.escaped then 'Editing escaped bytes: use \\\\, \\n, \\r, \\t, or \\xHH.' else ''
      end
    elseif row.control ~= 'choice' then
      state.message = row.description or 'Select a child option, or use Add, Remove, and Reset.'
    end
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
  local bounds = state.graphBounds
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

cancelEdit = function(state: State): ()
  state.edit, state.text = nil, ''
end

localPoint = function(state: State, point: graph.Point): graph.Point
  return { x = point.x - state.graphBounds.x, y = point.y - state.graphBounds.y }
end

refresh = function(state: State): ()
  state.projected = projection.snapshot(state.service:snapshot())
  state.entries = state.service:entries()
  state.catalog = state.service:catalog()
  local layout = toolbarLayout.compute(
    state.width,
    state.height,
    state.edit ~= nil,
    state.view.searchActive,
    nil,
    state.presentation,
    state.tab
  )
  state.view.viewport = { x = layout.graphBounds.width, y = layout.graphBounds.height }
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
  state.rows, state.rowIndices = {}, {}
  state.wrappedDetails = false
  local selectedRow = if state.tab == 'configure' and state.row then state.editorRows[state.row] else nil
  local valueField: ('boolean' | 'choice')? = nil
  if selectedRow and not selectedRow.readOnly then
    if selectedRow.control == 'boolean' or selectedRow.control == 'choice' then
      valueField = selectedRow.control
    end
  end
  layout = toolbarLayout.compute(
    state.width,
    state.height,
    state.edit ~= nil,
    state.view.searchActive,
    valueField,
    state.presentation,
    state.tab
  )
  state.bodyTop = layout.detailsTop
  state.graphBounds, state.bodyBounds = layout.graphBounds, layout.bodyBounds
  state.editBounds, state.searchBounds = layout.editBounds, layout.searchBounds
  state.view.viewport = { x = layout.graphBounds.width, y = layout.graphBounds.height }
  if state.tab == 'catalog' then
    state.lines = { 'Known session entries', 'Select a removed entry, then Load.' }
    refreshRows(state)
  elseif state.tab == 'configure' and entry and entry.schema then
    state.lines = { entry.id .. ': configuration draft', 'Callbacks and opaque values remain read-only.' }
    refreshRows(state)
    if state.message == '' then
      state.message = tostring(#state.editorRows) .. ' options; use Previous/Next to scroll.'
    end
  else
    local all = details.lines(
      state.projected,
      state.view.selection,
      state.entries,
      brokers.snapshot(state.readers),
      function(registration)
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
    local wrapDetails = state.wrapDetails
    if wrapDetails then
      all = wrapDetails(all, state.sidebar)
      state.wrappedDetails = true
    elseif state.measuredRecords == all and state.measuredDetails then
      all = state.measuredDetails
      state.wrappedDetails = true
    end
    state.scroll = math.clamp(state.scroll, 0, math.max(0, #all - 1))
    state.lines = {}
    for index = state.scroll + 1, #all do
      state.lines[#state.lines + 1] = all[index]
    end
  end
  state.buttons, state.actions = controllerActions.build(state, entry, {
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

refreshRows = function(state: State): ()
  if state.tab ~= 'catalog' and state.tab ~= 'configure' then
    return
  end
  local count = if state.tab == 'catalog' then #state.catalog else #state.editorRows
  state.scroll = math.clamp(state.scroll, 0, math.max(0, count - 1))
  state.rows, state.rowIndices = {}, {}
  local step = state.rowHeight + state.rowSpacing
  local available = math.max(1, math.floor(state.bodyBounds.height / step))
  for index = state.scroll + 1, math.min(count, state.scroll + available) do
    local known, row = state.catalog[index], state.editorRows[index]
    local catalog = state.tab == 'catalog'
    state.rows[#state.rows + 1] = {
      x = state.bodyBounds.x,
      y = state.bodyBounds.y + #state.rows * step,
      width = state.bodyBounds.width,
      height = state.rowHeight,
      label = if catalog then known.id else row.label,
      value = if catalog then (if known.installed then 'installed' else 'removed') else row.text,
      selected = if catalog then known.id == state.catalogSelection else index == state.row,
      editable = if catalog then not known.installed else not row.readOnly,
    }
    state.rowIndices[#state.rowIndices + 1] = index
  end
end

return controller

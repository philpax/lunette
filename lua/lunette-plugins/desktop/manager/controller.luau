-- Maps logical pixel input to graph navigation, schema drafts, and session composition actions.

local composition = require '@lunette-contracts/composition'
local graph = require './graph'
local view = require './view'
local projection = require './projection'
local details = require './details'
local brokers = require './brokers'
local draw = require './draw'
local editor = require './editor'

local config = require './config'

local controller = {}

type Edit = { operation: 'set' | 'add', path: editor.Path }
type Action = { run: () -> (), editor: boolean }

export type State = {
  view: view.State,
  service: composition.Service,
  projected: projection.Projected,
  entries: { composition.Entry },
  readers: { brokers.Reader },
  width: number,
  height: number,
  sidebar: number,
  tab: 'inspect' | 'configure' | 'catalog',
  catalog: { read [number]: composition.KnownEntry },
  catalogSelection: string?,
  bodyTop: number,
  scroll: number,
  draft: editor.Model?,
  draftEntry: string?,
  row: number?,
  edit: Edit?,
  text: string,
  message: string,
  buttons: { draw.Button },
  actions: { Action },
  rows: { draw.Row },
  rowIndices: { number },
  editorRows: { read [number]: editor.Row },
  lines: { string },
  wrappedDetails: boolean,
  wrapDetails: (({ string }, number) -> { string })?,
  close: (() -> ())?,
  pressedButton: string?,
}

local refresh: (State) -> ()
local attempt: (State, Action) -> ()
local cancelEdit: (State) -> ()
local selectedEntry: (State) -> composition.Entry?
local controls: (State) -> ()
local change: (State, editor.Model?, editor.Problem?) -> ()
local activateRow: (State) -> ()
local commitText: (State) -> ()

function controller.new(
  service: composition.Service,
  readers: { brokers.Reader },
  width: number,
  height: number,
  wrapDetails: (({ string }, number) -> { string })?,
  close: (() -> ())?
): State
  assert(width >= config.minimumWidth and width < math.huge, 'manager controller: invalid logical width')
  assert(height >= config.minimumHeight and height < math.huge, 'manager controller: invalid logical height')
  local sidebar = math.min(440, width * 0.4)
  local state: State = {
    view = view.new { x = width - sidebar, y = height },
    service = service,
    projected = projection.snapshot(service:snapshot()),
    entries = {},
    readers = readers,
    width = width,
    height = height,
    sidebar = sidebar,
    tab = 'inspect',
    catalog = {},
    catalogSelection = nil,
    bodyTop = 202,
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
    wrappedDetails = false,
    wrapDetails = wrapDetails,
    close = close,
    pressedButton = nil,
  }
  refresh(state)
  return state
end

function controller.update(state: State): ()
  refresh(state)
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
    footer = if state.edit
      then 'Editing: ' .. state.text
      else if state.view.searchActive then 'Search: ' .. state.view.query else state.message,
  }
end

function controller.press(state: State, point: graph.Point): ()
  state.pressedButton = nil
  local index = draw.hit(state.buttons, point)
  if index then
    state.pressedButton = state.buttons[index].label
    view.cancel(state.view)
    return
  end
  for _, button in state.buttons do
    if
      point.x >= button.x
      and point.x < button.x + button.width
      and point.y >= button.y
      and point.y < button.y + button.height
    then
      return
    end
  end
  for rowIndex, row in state.rows do
    if point.x >= row.x and point.x <= row.x + row.width and point.y >= row.y and point.y <= row.y + row.height then
      cancelEdit(state)
      state.row = state.rowIndices[rowIndex]
      if state.tab == 'catalog' then
        local entry = state.catalog[state.row :: number]
        state.catalogSelection = if entry then entry.id else nil
        refresh(state)
      else
        activateRow(state)
      end
      return
    end
  end
  if point.x < state.view.viewport.x then
    cancelEdit(state)
    view.press(state.view, point)
  end
end

function controller.move(state: State, point: graph.Point): ()
  view.move(state.view, point)
end

function controller.release(state: State, point: graph.Point): ()
  local pressed = state.pressedButton
  state.pressedButton = nil
  if pressed then
    local index = draw.hit(state.buttons, point)
    if index and state.buttons[index].label == pressed then
      cancelEdit(state)
      attempt(state, state.actions[index])
    end
    return
  end
  local previous = state.view.selection
  view.release(state.view, point)
  if previous ~= state.view.selection then
    state.scroll = 0
    state.draft = nil
    state.draftEntry = nil
    state.row = nil
    cancelEdit(state)
  end
  refresh(state)
end

function controller.cancel(state: State): ()
  state.pressedButton = nil
  view.cancel(state.view)
  state.view.searchActive = false
  cancelEdit(state)
end

function controller.text(state: State, text: string): boolean
  if state.edit then
    state.text ..= text
    return true
  end
  return view.text(state.view, text)
end

function controller.key(state: State, key: KeyCode): boolean
  if key == 'tab' and state.edit then
    cancelEdit(state)
  end
  if state.edit then
    if key == 'escape' then
      cancelEdit(state)
    elseif key == 'return' then
      commitText(state)
    elseif key == 'backspace' then
      local start = utf8.offset(state.text, -1)
      if start then
        state.text = state.text:sub(1, start - 1)
      end
    end
    return true
  end
  if state.view.searchActive then
    return view.key(state.view, key)
  end
  if key == 'pageup' then
    state.scroll = math.max(0, state.scroll - 10)
  elseif key == 'pagedown' then
    state.scroll += 10
  elseif key == 'up' or key == 'down' then
    state.scroll = math.max(0, state.scroll + (if key == 'up' then -1 else 1))
  elseif key == 'tab' then
    state.tab = if state.tab == 'inspect' then 'configure' else 'inspect'
    state.scroll = 0
  elseif key == 'return' and state.tab == 'configure' then
    activateRow(state)
  else
    return view.key(state.view, key)
  end
  refresh(state)
  return true
end

selectedEntry = function(state: State): composition.Entry?
  local selection = state.view.selection
  return if selection and selection.kind == 'node' then details.entry(state.entries, selection.id) else nil
end

cancelEdit = function(state: State): ()
  state.edit = nil
  state.text = ''
end

attempt = function(state: State, action: Action): ()
  local ok, problem = pcall(action.run)
  if not ok then
    state.message = tostring(problem)
  elseif not action.editor then
    state.message = 'Action completed; state and diagnostics appear in the inspector.'
  end
  refresh(state)
end

change = function(state: State, nextModel: editor.Model?, problem: editor.Problem?): ()
  if nextModel then
    state.draft = nextModel
    state.message = 'Draft changed; Apply validates before replacing the activation.'
  elseif problem then
    state.message = problem.message
  end
end

activateRow = function(state: State): ()
  local model = state.draft
  local index = state.row
  local row = if index then state.editorRows[index] else nil
  cancelEdit(state)
  if not model or not row then
    return
  end
  if row.readOnly then
    state.message = row.reason or 'This value is read-only.'
  elseif row.control == 'boolean' then
    change(state, editor.toggle(model, row.path))
  elseif row.control == 'choice' and row.choices then
    local current = 0
    for choiceIndex, choice in row.choices do
      if choice == row.value then
        current = choiceIndex
        break
      end
    end
    change(state, editor.set(model, row.path, row.choices[current % #row.choices + 1]))
  elseif row.control == 'number' or row.control == 'string' then
    state.text = row.text
    state.edit = { operation = 'set', path = row.path }
  else
    state.message = row.description or 'Select a child option, or use Add, Remove, and Reset.'
  end
  refresh(state)
end

commitText = function(state: State): ()
  local model, edit = state.draft, state.edit
  if model and edit then
    if edit.operation == 'add' then
      change(state, editor.add(model, edit.path, state.text))
    else
      change(state, editor.set(model, edit.path, state.text))
    end
  end
  cancelEdit(state)
  refresh(state)
end

controls = function(state: State): ()
  state.buttons, state.actions = {}, {}
  local entry = selectedEntry(state)
  local function button(label: string, enabled: boolean, run: () -> (), editorAction: boolean?): ()
    local index = #state.buttons
    state.buttons[index + 1] = {
      x = state.width - state.sidebar + 10 + (index % 3) * (state.sidebar - 20) / 3,
      y = 8 + math.floor(index / 3) * 30,
      width = (state.sidebar - 26) / 3,
      height = 26,
      label = label,
      enabled = enabled,
    }
    state.actions[index + 1] = { run = run, editor = editorAction == true }
  end
  button('Inspect', true, function()
    state.tab = 'inspect'
    state.scroll = 0
  end)
  button('Configure', entry ~= nil and entry.configurable, function()
    state.tab = 'configure'
    state.scroll = 0
  end)
  button('Fit', true, function()
    view.reset(state.view)
  end)
  local id = if entry then entry.id else ''
  local mutable = entry ~= nil and not entry.protected
  button('Enable', entry ~= nil and not entry.enabled, function()
    state.service:enable(id)
  end)
  button('Disable', mutable and entry ~= nil and entry.enabled, function()
    state.service:disable(id)
  end)
  button('Reload', mutable, function()
    state.service:reload(id)
  end)
  button('Recover', mutable and entry ~= nil and entry.previousConfig ~= nil, function()
    state.service:recover(id)
    state.draft = nil
  end)
  button('Remove', mutable, function()
    state.service:remove(id)
  end)
  button('Apply', mutable and entry ~= nil and entry.configurable and state.draft ~= nil, function()
    local model = state.draft
    if model then
      state.service:configure(id, editor.draft(model))
      state.draft = nil
    end
  end)
  local row = if state.row then state.editorRows[state.row] else nil
  button(if row and row.value ~= nil then 'Unset' else 'Set', row ~= nil and row.optional and row.canReset, function()
    if state.draft and row then
      change(state, editor.set(state.draft, row.path, if row.value == nil then true else nil))
    end
  end, true)
  button('Reset', row ~= nil and row.canReset, function()
    if state.draft and row then
      change(state, editor.reset(state.draft, row.path))
    end
  end, true)
  button('Add', row ~= nil and row.canAdd, function()
    if state.draft and row then
      if row.control == 'map' then
        state.edit = { operation = 'add', path = row.path }
        state.text = ''
      else
        change(state, editor.add(state.draft, row.path))
      end
    end
  end, true)
  button('Remove value', row ~= nil and row.canRemove, function()
    if state.draft and row then
      change(state, editor.remove(state.draft, row.path))
    end
  end, true)
  button('Previous', state.scroll > 0, function()
    state.scroll = math.max(0, state.scroll - 10)
  end)
  button('Next', true, function()
    state.scroll += 10
  end)
  button('Transitive', true, function()
    state.view.transitive = not state.view.transitive
  end)
  button('Providers', true, function()
    state.view.mode = 'providers'
  end)
  button('Consumers', true, function()
    state.view.mode = 'consumers'
  end)
  button('All', true, function()
    state.view.mode = 'all'
  end)
  button('Affected', true, function()
    state.view.mode = 'impact'
  end)
  button('Catalog', true, function()
    state.tab = 'catalog'
    state.scroll = 0
  end)
  local loadable = false
  for _, known in state.catalog do
    if known.id == state.catalogSelection and not known.installed then
      loadable = true
    end
  end
  button('Load', loadable, function()
    local id = state.catalogSelection
    if id then
      state.service:restore(id)
    end
  end)
  state.bodyTop = 18 + math.ceil(#state.buttons / 3) * 30
  local navigationIndex = 0
  local function navigation(label: string, enabled: boolean, run: () -> ()): ()
    local index = #state.buttons + 1
    local width = (state.view.viewport.x - 24) / 5
    state.buttons[index] = {
      x = 8 + navigationIndex * (width + 2),
      y = 8,
      width = width,
      height = 26,
      label = label,
      enabled = enabled,
    }
    state.actions[index] = { run = run, editor = true }
    navigationIndex += 1
  end
  navigation('Zoom in', true, function()
    view.zoom(state.view, { x = state.view.viewport.x / 2, y = state.view.viewport.y / 2 }, 1.2)
  end)
  navigation('Zoom out', true, function()
    view.zoom(state.view, { x = state.view.viewport.x / 2, y = state.view.viewport.y / 2 }, 1 / 1.2)
  end)
  local selection = state.view.selection
  navigation('Focus', selection ~= nil and selection.kind == 'node', function()
    view.focus(state.view)
  end)
  navigation('Search', true, function()
    view.search(state.view)
  end)
  navigation('Close', state.close ~= nil, function()
    local close = state.close
    if close then
      close()
    end
  end)
end

refresh = function(state: State): ()
  state.projected = projection.snapshot(state.service:snapshot())
  state.entries = state.service:entries()
  state.catalog = state.service:catalog()
  view.update(state.view, state.projected.graph)
  local entry = selectedEntry(state)
  if state.tab == 'configure' and entry and entry.configurable and entry.schema then
    if state.draftEntry ~= entry.id or not state.draft then
      state.draft = editor.new(entry.schema, entry.config)
      state.draftEntry = entry.id
      state.row = nil
      cancelEdit(state)
    end
    state.editorRows = editor.rows(state.draft :: editor.Model)
  else
    state.editorRows = {}
    state.row = nil
    cancelEdit(state)
    if not entry or state.draftEntry ~= entry.id then
      state.draft, state.draftEntry = nil, nil
    end
  end
  controls(state)
  state.rows, state.rowIndices = {}, {}
  state.wrappedDetails = false
  local top = state.bodyTop + 68
  local available = math.max(1, math.floor((state.height - top - 64) / 36))
  if state.tab == 'catalog' then
    state.scroll = math.clamp(state.scroll, 0, math.max(0, #state.catalog - 1))
    state.lines = { 'Known session entries', 'Select a removed entry, then Load.' }
    for index = state.scroll + 1, math.min(#state.catalog, state.scroll + available) do
      local known = state.catalog[index]
      state.rows[#state.rows + 1] = {
        x = state.width - state.sidebar + 10,
        y = top + #state.rows * 36,
        width = state.sidebar - 20,
        height = 34,
        label = known.id,
        value = if known.installed then 'installed' else 'removed',
        selected = known.id == state.catalogSelection,
        editable = not known.installed,
      }
      state.rowIndices[#state.rowIndices + 1] = index
    end
  elseif state.tab == 'configure' and entry and entry.configurable and entry.schema then
    state.scroll = math.clamp(state.scroll, 0, math.max(0, #state.editorRows - 1))
    state.lines = { entry.id .. ': configuration draft', 'Callbacks and opaque values remain read-only.' }
    for index = state.scroll + 1, math.min(#state.editorRows, state.scroll + available) do
      local row = state.editorRows[index]
      state.rows[#state.rows + 1] = {
        x = state.width - state.sidebar + 10,
        y = top + #state.rows * 36,
        width = state.sidebar - 20,
        height = 34,
        label = row.label,
        value = row.text,
        selected = index == state.row,
        editable = not row.readOnly,
      }
      state.rowIndices[#state.rowIndices + 1] = index
    end
    state.message = if state.message == ''
      then tostring(#state.editorRows) .. ' options; use Previous/Next to scroll.'
      else state.message
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
    local wrapDetails = state.wrapDetails
    if wrapDetails then
      all = wrapDetails(all, state.sidebar)
      state.wrappedDetails = true
    end
    state.scroll = math.clamp(state.scroll, 0, math.max(0, #all - 1))
    state.lines = {}
    for index = state.scroll + 1, #all do
      state.lines[#state.lines + 1] = all[index]
    end
  end
end

return controller

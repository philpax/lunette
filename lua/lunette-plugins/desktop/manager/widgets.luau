-- Retains public UI handles while the controller owns composition and draft decisions.
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local theme = require '@lunette-contracts/theme'
local controller = require './controller'
local geometry = require './graph-geometry'
local draw = require './draw'
local view = require './view'
local vocabulary = require '@lunette-contracts/vocabulary'
local passState = require '@lunette-plugins/pass-state'

local widgets = {}

type Retained = {
  handle: ui.Control,
  kind: ui.Kind,
  label: string,
  bounds: ui.Bounds,
  enabled: boolean,
  items: { read [number]: ui.Item }?,
  selected: string?,
}
export type Shell = {
  read update: () -> (),
  read cancel: () -> (),
  read destroy: () -> (),
}

type Compact = 'toolbar' | 'field' | 'choice'
local function compact(tokens: theme.Theme, kind: Compact): ui.ThemeOverrides
  if kind == 'toolbar' then
    return { padding = math.min(tokens.metrics.padding, 3), fontSize = math.min(tokens.typography.smallSize, 16) }
  elseif kind == 'field' then
    return { padding = math.min(tokens.metrics.padding, 5), fontSize = math.min(tokens.typography.bodySize, 20) }
  end
  return {
    rowHeight = math.min(tokens.metrics.rowHeight, 40),
    padding = math.min(tokens.metrics.padding, 5),
    spacing = math.min(tokens.metrics.spacing, 6),
    fontSize = math.min(tokens.typography.bodySize, 20),
  }
end

local function equal(left: unknown, right: unknown): boolean
  if left == right then
    return true
  end
  if type(left) ~= 'table' or type(right) ~= 'table' then
    return false
  end
  local a, b = left :: { [unknown]: unknown }, right :: { [unknown]: unknown }
  for key, value in a do
    if not equal(value, b[key]) then
      return false
    end
  end
  for key in b do
    if a[key] == nil then
      return false
    end
  end
  return true
end

local function pathId(path: { read [number]: string | number }): string
  local parts = { 'row' }
  for _, part in path do
    local value = tostring(part):gsub('%%', '%%25'):gsub('/', '%%2f')
    parts[#parts + 1] = (if type(part) == 'number' then 'n:' else 's:') .. value
  end
  return table.concat(parts, '/')
end

function widgets.new(panel: ui.Panel, owner: plugin.Context, state: controller.State, themes: theme.Service): Shell
  local retained: { [string]: Retained } = {}
  local layers: { [string]: Compact } = {}
  local dead = false
  local measuredFont: Font? = nil
  local measuredSize: number? = nil
  local function themed(id: string, kind: Compact): ui.ThemeOverrides
    layers[id] = kind
    return compact(themes:current().theme, kind)
  end
  local function custom(pass: Pass, visual: ui.Visual, run: (draw.Style) -> ()): ()
    if dead then
      return
    end
    local font, size = visual.theme.font, visual.theme.fontSize
    if state.measuredRecords ~= state.detailRecords or measuredFont ~= font or measuredSize ~= size then
      controller.measureDetails(state, font, size)
      measuredFont, measuredSize = font, size
    end
    passState.withRestore(pass, function(): ()
      pass:setFont(font)
      run { theme = themes:current().theme, visual = visual.theme }
    end)
  end
  local used: { [string]: boolean } = {}
  local graphItems: { read [number]: ui.RegionItem } = {}
  local graphPointer: vocabulary.Pointer? = nil
  local publishedView: view.State = table.clone(state.view)
  local scrollRemainder = 0
  local editIdentity: string? = nil
  local updating = false
  local update: () -> ()
  local function retire(id: string): ()
    local record = retained[id]
    if record then
      retained[id], layers[id] = nil, nil
      record.handle:destroy()
    end
  end
  local function retain(
    id: string,
    kind: ui.Kind,
    label: string,
    bounds: ui.Bounds,
    enabled: boolean,
    create: () -> ui.Control
  ): Retained
    used[id] = true
    local record = retained[id]
    if record and (record.handle.dead or record.kind ~= kind or record.label ~= label) then
      retire(id)
      record = nil
    end
    if not record then
      local created: Retained = {
        handle = create(),
        kind = kind,
        label = label,
        bounds = bounds,
        enabled = enabled,
        items = nil,
        selected = nil,
      }
      retained[id] = created
      return created
    end
    if not equal(record.bounds, bounds) then
      record.bounds = bounds
      record.handle:setBounds(bounds)
    end
    if record.enabled ~= enabled then
      record.enabled = enabled
      record.handle:setEnabled(enabled)
    end
    return record
  end
  -- Lists and choices are created with their items, so only later changes are pushed.
  local function sync(record: Retained, items: { read [number]: ui.Item }, selected: string?): ()
    local handle = record.handle :: ui.List
    if record.items == nil then
      record.items, record.selected = items, selected
      return
    end
    if not equal(record.items, items) then
      record.items = items
      handle:setItems(items)
    end
    if record.selected ~= selected then
      record.selected = selected
      handle:setSelected(selected)
    end
  end
  themes:onChanged(owner, function(snapshot: theme.Snapshot): ()
    for id, kind in layers do
      local record = retained[id]
      if record and not record.handle.dead then
        record.handle:setTheme(compact(snapshot.theme, kind))
      end
    end
  end)
  local function cancelGraph(): ()
    if graphPointer == nil then
      return
    end
    graphPointer = nil
    controller.graphCancel(state)
    local record = retained.graph
    if record and not record.handle.dead then
      local region = record.handle :: ui.Region
      region:setItems(graphItems)
    end
  end
  local function invoke(id: string): ()
    cancelGraph()
    controller.invoke(state, id)
    update()
  end
  local function scroll(event: vocabulary.PointerEvent): ()
    if event.kind == 'scroll' and event.inside and event.dy ~= nil then
      scrollRemainder += event.dy / 36
      local rows = if scrollRemainder > 0 then math.floor(scrollRemainder) else math.ceil(scrollRemainder)
      if rows ~= 0 then
        scrollRemainder -= rows
        controller.scrollBy(state, rows)
        update()
      end
    end
  end
  local function graphEvent(event: vocabulary.PointerEvent): ()
    if event.kind == 'cancel' then
      if event.button == 'left' and event.pointer == graphPointer then
        graphPointer = nil
        controller.graphCancel(state)
      end
      update()
      return
    end
    if event.kind == 'scroll' then
      if event.inside and event.x ~= nil and event.y ~= nil and event.dy ~= nil then
        cancelGraph()
        controller.graphZoom(state, { x = event.x, y = event.y }, math.exp(-event.dy / 600))
        update()
      end
      return
    end
    local x, y = event.x, event.y
    if event.kind == 'press' then
      if event.button == 'left' and event.inside and x ~= nil and y ~= nil then
        graphPointer = event.pointer
        controller.graphPress(state, { x = x, y = y })
      end
    elseif event.kind == 'move' then
      if event.button == 'left' and event.pointer == graphPointer and x ~= nil and y ~= nil then
        controller.graphMove(state, { x = x, y = y })
      end
    elseif event.kind == 'release' then
      if event.button == 'left' and event.pointer == graphPointer then
        graphPointer = nil
        if x ~= nil and y ~= nil and event.inside then
          controller.graphRelease(state, { x = x, y = y }, publishedView)
        else
          if x ~= nil and y ~= nil then
            controller.graphMove(state, { x = x, y = y })
          end
          controller.graphCancel(state)
        end
      end
    else
      return
    end
    update()
  end
  local function list(
    id: string,
    label: string,
    bounds: ui.Bounds,
    items: { read [number]: ui.Item },
    selected: string?,
    onChange: (string) -> ()
  ): ()
    local record = retain(id, 'list', label, bounds, true, function()
      return panel:list(owner, {
        id = id,
        label = label,
        bounds = bounds,
        items = items,
        selected = selected,
        onChange = function(item: string): ()
          onChange(item)
          update()
        end,
      })
    end)
    sync(record, items, selected)
  end
  local function field(id: string, label: string, bounds: ui.Bounds, value: string): ui.TextField
    local created = retained[id] == nil
    local record = retain(id, 'text-field', label, bounds, true, function()
      return panel:textField(owner, {
        id = id,
        label = label,
        bounds = bounds,
        value = value,
        theme = themed(id, 'field'),
        z = 3,
        onChange = function(text: string): ()
          cancelGraph()
          if id == 'search-field' then
            controller.setSearch(state, text)
          else
            controller.setText(state, text)
          end
          update()
        end,
        onSubmit = function(text: string): ()
          cancelGraph()
          if id == 'search-field' then
            controller.setSearch(state, text)
            controller.endSearch(state)
          else
            controller.setText(state, text)
            controller.confirmText(state)
          end
          update()
        end,
        onCancel = function(_text: string): ()
          cancelGraph()
          if id == 'search-field' then
            controller.endSearch(state, false)
          else
            controller.cancelText(state, false)
          end
          update()
        end,
      })
    end)
    local handle = record.handle :: ui.TextField
    if handle:value() ~= value then
      handle:setValue(value)
    end
    if created then
      handle:focus()
    end
    return handle
  end
  local function configure(): ()
    local items: { ui.Item } = {}
    for _, row in state.editorRows do
      items[#items + 1] = table.freeze {
        id = pathId(row.path),
        label = row.label .. ': ' .. (if row.text == '' then '(empty)' else row.text),
        enabled = true,
      }
    end
    local selected = if state.row then state.editorRows[state.row] else nil
    list('rows', 'Configuration rows', state.layout.bodyBounds, items, selected and pathId(selected.path), function(id)
      for index, row in state.editorRows do
        if pathId(row.path) == id then
          controller.selectRow(state, index)
          return
        end
      end
    end)
    local fieldBounds = state.layout.editBounds
    if selected and not selected.readOnly and not state.edit then
      if selected.control == 'boolean' then
        assert(fieldBounds, 'manager widgets: boolean needs declared bounds')
        local label = selected.label .. ': ' .. tostring(selected.value)
        retain('boolean-field', 'button', label, fieldBounds, true, function()
          return panel:button(owner, {
            id = 'boolean-field',
            label = label,
            bounds = fieldBounds,
            theme = themed('boolean-field', 'field'),
            z = 3,
            onActivate = function(): ()
              controller.toggle(state)
              update()
            end,
          })
        end)
      elseif selected.control == 'choice' and selected.choices then
        assert(fieldBounds, 'manager widgets: choice needs declared bounds')
        local choices: { ui.Item } = {}
        local selectedId: string? = nil
        for index, value in selected.choices do
          local id = 'choice/' .. tostring(index)
          choices[#choices + 1] = table.freeze { id = id, label = tostring(value), enabled = true }
          if equal(value, selected.value) then
            selectedId = id
          end
        end
        local record = retain('choice-field', 'choice', selected.label, fieldBounds, true, function()
          return panel:choice(owner, {
            id = 'choice-field',
            label = selected.label,
            bounds = fieldBounds,
            theme = themed('choice-field', 'choice'),
            items = choices,
            selected = selectedId,
            z = 3,
            onChange = function(id: string): ()
              local index = tonumber(id:sub(8))
              if state.row and index then
                controller.choose(state, state.row, index)
                update()
              end
            end,
          })
        end)
        sync(record, choices, selectedId)
      end
    end
    if state.edit then
      assert(fieldBounds, 'manager widgets: text edit needs declared bounds')
      local identity = tostring(state.draftEntry) .. '/' .. state.edit.operation .. '/' .. pathId(state.edit.path)
      if editIdentity ~= identity then
        retire 'edit-field'
        editIdentity = identity
      end
      local handle =
        field('edit-field', if state.edit.operation == 'add' then 'Map key' else 'Value', fieldBounds, state.text)
      handle:setError(if state.message ~= '' then state.message else nil)
    else
      editIdentity = nil
    end
  end
  local function graphRegion(): ()
    local graphBounds = state.layout.graphBounds
    if graphPointer == nil then
      publishedView = table.clone(state.view)
    end
    local projected = geometry.project(publishedView, graphBounds)
    local record = retain('graph', 'region', 'Plugin graph', graphBounds, true, function()
      graphItems = projected.items
      return panel:region(owner, {
        id = 'graph',
        label = 'Plugin graph',
        bounds = graphBounds,
        items = graphItems,
        exclusive = true,
        z = -1,
        onPointer = graphEvent,
        draw = function(pass: Pass, visual: ui.Visual, _default: ui.Renderer): ()
          custom(pass, visual, function(style: draw.Style): ()
            draw.graph(pass, publishedView, visual.bounds, style, visual.clip)
          end)
        end,
      })
    end)
    -- Replacing region items cancels its captures, so a captured pan keeps the published items.
    if graphPointer == nil and not equal(graphItems, projected.items) then
      graphItems = projected.items
      local handle = record.handle :: ui.Region
      handle:setItems(graphItems)
    end
  end
  local function entryList(): ()
    local items: { ui.Item } = {}
    local selectedId: string? = nil
    local visible = view.visible(state.view)
    local selected = state.view.selection
    for _, entry in state.entries do
      if visible[entry.instanceId] then
        items[#items + 1] = {
          id = 'entry/' .. entry.id,
          label = entry.id .. ': ' .. entry.state .. (if entry.protected then ' [protected]' else ''),
        }
      end
      if selected and selected.kind == 'node' and selected.id == entry.instanceId then
        selectedId = 'entry/' .. entry.id
      end
    end
    list('entries', 'Plugin entries', state.layout.graphBounds, items, selectedId, function(id)
      for _, entry in state.entries do
        if id == 'entry/' .. entry.id then
          view.select(state.view, { kind = 'node', id = entry.instanceId })
          return
        end
      end
    end)
  end
  local function sidebarRegion(id: string, label: string, part: draw.SidebarPart, bounds: ui.Bounds, z: number): ()
    local interactive = part == 'details'
    retain(id, 'region', label, bounds, interactive, function()
      return panel:region(owner, {
        id = id,
        label = label,
        bounds = bounds,
        enabled = interactive,
        z = z,
        onPointer = if interactive then scroll else nil,
        draw = function(pass: Pass, visual: ui.Visual, _default: ui.Renderer): ()
          custom(pass, visual, function(style: draw.Style): ()
            draw.details(pass, controller.options(state), visual.clip, part, style)
          end)
        end,
      })
    end)
  end
  update = function(): ()
    if updating or dead or panel.dead then
      return
    end
    updating = true
    local ok, problem = pcall(function(): ()
      controller.update(state)
      used = {}
      if state.presentation == 'graph' then
        graphRegion()
      else
        entryList()
      end
      local sidebar = draw.sidebarGeometry(controller.options(state))
      sidebarRegion('sidebar-background', 'Sidebar background', 'background', sidebar.background, -2)
      if sidebar.details.height > 0 then
        sidebarRegion('details', 'Inspection details', 'details', sidebar.details, -1)
      end
      sidebarRegion('sidebar-footer', 'Sidebar status', 'footer', sidebar.footer, -1)
      for _, button in state.buttons do
        local id = button.id
        retain(id, 'button', button.label, button.bounds, button.enabled, function()
          return panel:button(owner, {
            id = id,
            label = button.label,
            bounds = button.bounds,
            enabled = button.enabled,
            theme = themed(id, 'toolbar'),
            z = 2,
            onActivate = function(): ()
              invoke(id)
            end,
          })
        end)
      end
      if state.tab == 'catalog' then
        local items: { ui.Item } = {}
        for _, known in state.catalog do
          items[#items + 1] = table.freeze {
            id = 'catalog/' .. known.id,
            label = known.id .. ': ' .. (if known.installed then 'installed' else 'removed'),
            enabled = true,
          }
        end
        local selected = if state.catalogSelection then 'catalog/' .. state.catalogSelection else nil
        list('catalog-list', 'Catalog entries', state.layout.bodyBounds, items, selected, function(id)
          controller.selectCatalog(state, id:sub(9))
        end)
      elseif state.tab == 'configure' and state.draft then
        configure()
      end
      if state.view.searchActive then
        assert(state.layout.searchBounds, 'manager widgets: search needs declared bounds')
        field('search-field', 'Search plugins', state.layout.searchBounds, state.view.query)
      end
      for id in retained do
        if not used[id] then
          retire(id)
        end
      end
    end)
    updating = false
    if not ok then
      error(problem, 0)
    end
  end
  local shell: Shell = {
    update = update,
    cancel = function(): ()
      graphPointer = nil
      scrollRemainder = 0
      controller.graphCancel(state)
      controller.endSearch(state)
      controller.cancelText(state)
      for _, record in retained do
        if record.kind == 'text-field' then
          (record.handle :: ui.TextField):blur()
        end
      end
    end,
    destroy = function(): ()
      dead = true
      graphPointer = nil
      controller.graphCancel(state)
      for id in retained do
        retire(id)
      end
    end,
  }
  update()
  return shell
end

return widgets

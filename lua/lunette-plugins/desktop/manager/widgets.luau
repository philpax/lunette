-- Retains public UI handles while the controller owns composition and draft decisions.
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local surface = require '@lunette-contracts/surface'
local controller = require './controller'
local geometry = require './graph-geometry'
local draw = require './draw'
local view = require './view'

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
export type Shell = { read update: () -> (), read cancel: () -> (), read destroy: () -> () }

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

function widgets.new(panel: ui.Panel, owner: plugin.Context, state: controller.State): Shell
  local retained: { [string]: Retained } = {}
  local used: { [string]: boolean } = {}
  local graphItems: { read [number]: ui.RegionItem } = {}
  local graphPointer: surface.Pointer? = nil
  local publishedView: view.State = table.clone(state.view)
  local rowPress: { [string]: string } = {}
  local scrollRemainder = 0
  local editIdentity: string? = nil
  local updating = false
  local update: () -> ()
  local function retire(id: string): ()
    local record = retained[id]
    if record then
      retained[id] = nil
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
  local function scroll(event: surface.PointerEvent): ()
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
  local function graphEvent(event: surface.PointerEvent): ()
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
    elseif event.kind == 'cancel' then
      if event.button == 'left' and event.pointer == graphPointer then
        graphPointer = nil
        controller.graphCancel(state)
      end
    else
      return
    end
    update()
  end
  local regionItems: { [string]: { read [number]: ui.RegionItem } } = {}
  local function collection(id: string, items: { ui.RegionItem }, bounds: ui.Bounds): ()
    local function itemAt(x: number?, y: number?): string?
      if x == nil or y == nil then
        return nil
      end
      for _, item in regionItems[id] or {} do
        local box = item.bounds
        if x >= box.x and x < box.x + box.width and y >= box.y and y < box.y + box.height then
          return item.id
        end
      end
      return nil
    end
    local label = if id == 'catalog-list' then 'Catalog entries' else 'Configuration rows'
    local record = retain(id, 'region', label, bounds, true, function()
      regionItems[id] = items
      return panel:region(owner, {
        id = id,
        label = if id == 'catalog-list' then 'Catalog entries' else 'Configuration rows',
        bounds = bounds,
        items = items,
        exclusive = true,
        z = 1,
        draw = function(pass: Pass, visual: ui.Visual, _default: ui.Renderer): ()
          draw.details(pass, controller.options(state), visual.clip, 'rows')
        end,
        onPointer = function(event: surface.PointerEvent): ()
          if event.kind == 'scroll' then
            scroll(event)
            return
          end
          if event.kind == 'press' then
            if event.button == 'left' and event.inside then
              rowPress[id] = itemAt(event.x, event.y)
            end
          elseif event.kind == 'cancel' then
            if event.button == 'left' then
              rowPress[id] = nil
            end
          elseif event.kind == 'release' then
            if event.button ~= 'left' then
              return
            end
            local pressed = rowPress[id]
            rowPress[id] = nil
            if not pressed or not event.inside or itemAt(event.x, event.y) ~= pressed then
              return
            end
            if id == 'catalog-list' then
              controller.selectCatalog(state, pressed:sub(9))
            else
              for index, row in state.editorRows do
                if pathId(row.path) == pressed then
                  controller.selectRow(state, index, row.control ~= 'boolean' and row.control ~= 'choice')
                  break
                end
              end
            end
            update()
          end
        end,
      })
    end)
    if not equal(regionItems[id], items) then
      regionItems[id] = items
      local handle = record.handle :: ui.Region
      handle:setItems(items)
    end
  end
  local function field(id: string, label: string, bounds: ui.Bounds, value: string): ui.TextField
    local created = retained[id] == nil
    local record = retain(id, 'text-field', label, bounds, true, function()
      return panel:textField(owner, {
        id = id,
        label = label,
        bounds = bounds,
        value = value,
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
            controller.endSearch(state)
          else
            controller.cancelText(state)
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
  update = function(): ()
    if updating or panel.dead then
      return
    end
    updating = true
    local ok, problem = pcall(function(): ()
      controller.update(state)
      used = {}
      local graphBounds = state.graphBounds
      if graphPointer == nil then
        publishedView = table.clone(state.view)
      end
      local projected = geometry.project(publishedView, graphBounds)
      local graphRecord = retain('graph', 'region', 'Plugin graph', graphBounds, true, function()
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
            draw.graph(pass, publishedView, visual.clip)
          end,
        })
      end)
      if graphPointer == nil and not equal(graphItems, projected.items) then
        graphItems = projected.items
        local handle = graphRecord.handle :: ui.Region
        handle:setItems(graphItems)
      end
      local sidebar = draw.sidebarGeometry(controller.options(state))
      retain('sidebar-background', 'region', 'Sidebar background', sidebar.background, false, function()
        return panel:region(owner, {
          id = 'sidebar-background',
          label = 'Sidebar background',
          bounds = sidebar.background,
          enabled = false,
          z = -2,
          draw = function(pass: Pass, visual: ui.Visual, _default: ui.Renderer): ()
            draw.details(pass, controller.options(state), visual.clip, 'background')
          end,
        })
      end)
      if sidebar.details.height > 0 then
        retain('details', 'region', 'Inspection details', sidebar.details, true, function()
          return panel:region(owner, {
            id = 'details',
            label = 'Inspection details',
            bounds = sidebar.details,
            z = -1,
            onPointer = scroll,
            draw = function(pass: Pass, visual: ui.Visual, _default: ui.Renderer): ()
              draw.details(pass, controller.options(state), visual.clip, 'details')
            end,
          })
        end)
      end
      retain('sidebar-footer', 'region', 'Sidebar status', sidebar.footer, false, function()
        return panel:region(owner, {
          id = 'sidebar-footer',
          label = 'Sidebar status',
          bounds = sidebar.footer,
          enabled = false,
          z = -1,
          draw = function(pass: Pass, visual: ui.Visual, _default: ui.Renderer): ()
            draw.details(pass, controller.options(state), visual.clip, 'footer')
          end,
        })
      end)
      for _, button in state.buttons do
        local id, bounds = button.id, { x = button.x, y = button.y, width = button.width, height = button.height }
        retain(id, 'button', button.label, bounds, button.enabled, function()
          return panel:button(owner, {
            id = id,
            label = button.label,
            bounds = bounds,
            enabled = button.enabled,
            z = 2,
            onActivate = function(): ()
              invoke(id)
            end,
          })
        end)
      end
      local body = state.bodyBounds
      if state.tab == 'catalog' then
        local items: { ui.RegionItem } = {}
        for visibleIndex, row in state.rows do
          local index = state.rowIndices[visibleIndex]
          local entry = state.catalog[index]
          if entry then
            items[#items + 1] = table.freeze {
              id = 'catalog/' .. entry.id,
              label = row.label,
              bounds = table.freeze { x = row.x, y = row.y, width = row.width, height = row.height },
            }
          end
        end
        collection('catalog-list', items, body)
      elseif state.tab == 'configure' then
        local items: { ui.RegionItem } = {}
        for visibleIndex, row in state.rows do
          local index = state.rowIndices[visibleIndex]
          local editorRow = state.editorRows[index]
          if editorRow then
            items[#items + 1] = table.freeze {
              id = pathId(editorRow.path),
              label = row.label .. ': ' .. (if row.value == '' then '(empty)' else row.value),
              bounds = table.freeze { x = row.x, y = row.y, width = row.width, height = row.height },
            }
          end
        end
        local selected = if state.row then state.editorRows[state.row] else nil
        collection('rows', items, body)
        local fieldBounds = state.editBounds
        if selected and not selected.readOnly and not state.edit then
          if selected.control == 'boolean' then
            assert(fieldBounds, 'manager widgets: boolean needs declared bounds')
            local label = selected.label .. ': ' .. tostring(selected.value)
            retain('boolean-field', 'button', label, fieldBounds, true, function()
              return panel:button(owner, {
                id = 'boolean-field',
                label = selected.label .. ': ' .. tostring(selected.value),
                bounds = fieldBounds,
                z = 3,
                onActivate = function(): ()
                  if state.row then
                    controller.selectRow(state, state.row, true)
                    update()
                  end
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
                theme = { rowHeight = 40, padding = 8, spacing = 6 },
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
            local handle = record.handle :: ui.Choice
            if record.items == nil then
              record.items, record.selected = choices, selectedId
            else
              if not equal(record.items, choices) then
                record.items = choices
                handle:setItems(choices)
              end
              if record.selected ~= selectedId then
                record.selected = selectedId
                handle:setSelected(selectedId)
              end
            end
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
      if state.view.searchActive then
        assert(state.searchBounds, 'manager widgets: search needs declared bounds')
        field('search-field', 'Search plugins', state.searchBounds, state.view.query)
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

-- An optional shared VR panel exposes all backdrop choices without physical keyboard input.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local audio = require '@lunette-contracts/audio'
local ui = require '@lunette-contracts/ui'
local menu = require '@lunette-contracts/menu'
local selection = require './selection'

local controls = {}
export type Renderer = { read enabled: () -> boolean, read setEnabled: (boolean) -> () }
export type Row = { read id: string, read label: string, read process: lunette.Process }
type RowToken = { read token: string, read process: lunette.Process }
type RowDetails = { process: lunette.Process, names: { string }, label: string?, state: audio.State? }
local modeItems: { ui.Item } = {
  { id = 'system', label = 'System mix' },
  { id = 'application', label = 'Pinned application' },
  { id = 'attention', label = 'Attention' },
}
local presets: { ui.Item } = {
  { id = '0', label = 'None' },
  { id = '0.25', label = 'Low' },
  { id = '0.5', label = 'Medium' },
  { id = '0.75', label = 'High' },
  { id = '1', label = 'Full' },
}
local diagnosticItems: { ui.Item } = {
  { id = 'none', label = 'Off' },
  { id = 'direction', label = 'Sky direction' },
  { id = 'coordinates', label = 'Field coordinates' },
  { id = 'cells', label = 'Noise cells' },
  { id = 'density', label = 'Field density' },
  { id = 'field', label = 'Field, boosted' },
}
local selectedPreset: (number) -> string
local rowState: (audio.State?, boolean) -> string

-- Numeric IDs narrow the lookup; exact process equality rejects stale handles and matches fresh wrappers.
function controls.rows(choice: selection.State, processes: { lunette.Process }, windows: { lunette.Window }): { Row }
  local details: { RowDetails } = {}
  local byId: { [number]: { RowDetails } } = {}
  for _, process in processes do
    if process.dead then
      continue
    end
    local entry: RowDetails = { process = process, names = {}, label = nil, state = nil }
    details[#details + 1] = entry
    local candidates = byId[process.id]
    if candidates == nil then
      candidates = {}
      byId[process.id] = candidates
    end
    candidates[#candidates + 1] = entry
  end
  for _, window in windows do
    if window.dead then
      continue
    end
    local process = window.process
    local candidates = if process then byId[process.id] else nil
    if candidates then
      for _, entry in candidates do
        if entry.process == process then
          local title, appId = window.title, window.appId
          local label = if title and title ~= ''
            then title
            elseif appId and appId ~= '' then appId
            else 'Process ' .. tostring(entry.process.id)
          if appId and appId ~= '' and appId ~= label then
            label ..= ' (' .. appId .. ')'
          end
          entry.names[#entry.names + 1] = label
        end
      end
    end
  end
  for _, status in choice.processStatuses do
    local candidates = byId[status.process.id]
    if candidates then
      for _, entry in candidates do
        if entry.process == status.process then
          if entry.label == nil and status.label ~= '' then
            entry.label = status.label
          end
          if entry.state == nil then
            entry.state = status.state
          end
        end
      end
    end
  end
  local rows: { Row } = {}
  for _, entry in details do
    local process = entry.process
    local label = if #entry.names > 0
      then table.concat(entry.names, ', ')
      else entry.label or 'Process ' .. tostring(process.id)
    rows[#rows + 1] = {
      id = '',
      process = process,
      label = label .. ' · #' .. tostring(process.id) .. rowState(entry.state, choice.audioAvailable),
    }
  end
  return rows
end

function controls.attach(context: plugin.Context, choice: selection.State, renderer: Renderer): ()
  local child = plugin.consumer<<{}, {}>> {
    name = 'desktop/backdrop/controls',
    requires = { frame.capability, ui.capability, menu.capability },
    init = function(childContext: plugin.Context, _settings: {}): ()
      local frames: frame.Service = childContext:require(frame.capability)
      local uiService: ui.Service = childContext:require(ui.capability)
      local menus: menu.Service = childContext:require(menu.capability)
      local panel: ui.Panel
      local registration: menu.Registration? = nil
      local visible, live = false, true
      local rowSerial = 0
      local rowTokens: { RowToken } = {}
      local currentRows: { [string]: lunette.Process } = {}
      local shownItems: { ui.Item } = {}
      local statusText = ''
      local list: ui.List
      local sourceChoice: ui.Choice
      local enableChoice: ui.Choice
      local reactiveChoice: ui.Choice
      local responseChoice: ui.Choice
      local motionChoice: ui.Choice
      local diagnosticChoice: ui.Choice
      local pinButton: ui.Button
      local refresh: () -> ()
      local function setVisible(show: boolean): ()
        if not live or panel.dead then
          return
        end
        if choice.frozen ~= show then
          choice.revision += 1
        end
        visible, choice.frozen = show, show
        panel:setVisible(show)
        if registration then
          registration:update { selected = show }
        end
        refresh()
      end
      panel = uiService:newPanel(childContext, {
        name = 'desktop/backdrop/controls',
        pose = lovr.math.newMat4():translate(0, 1.35, -1.25),
        width = 0.86,
        height = 1.375,
        logicalWidth = 860,
        logicalHeight = 1375,
        theme = { rowHeight = 32, padding = 4, spacing = 4 },
        visible = false,
        grabbable = true,
        titlebar = {
          title = 'Backdrop',
          onClose = function(): ()
            setVisible(false)
          end,
        },
      })
      enableChoice = panel:choice {
        id = 'enabled',
        label = 'Backdrop',
        bounds = { x = 20, y = 20, width = 400, height = 116 },
        items = { { id = 'on', label = 'Enabled' }, { id = 'off', label = 'Disabled' } },
        onChange = function(id: string): ()
          renderer.setEnabled(id == 'on')
        end,
      }
      reactiveChoice = panel:choice {
        id = 'reactive',
        label = 'Audio reactivity',
        bounds = { x = 440, y = 20, width = 400, height = 116 },
        items = { { id = 'on', label = 'On' }, { id = 'off', label = 'Off' } },
        onChange = function(id: string): ()
          choice:setReactive(id == 'on')
        end,
      }
      sourceChoice = panel:choice {
        id = 'source-mode',
        label = 'Audio source',
        bounds = { x = 20, y = 150, width = 820, height = 152 },
        items = modeItems,
        onChange = function(id: string): ()
          if id == 'system' or id == 'application' or id == 'attention' then
            choice:setMode(id)
          end
        end,
      }
      pinButton = panel:button {
        id = 'pin-now',
        label = 'Pin the attended application (Attention source only)',
        bounds = { x = 20, y = 320, width = 820, height = 48 },
        onActivate = function(): ()
          local process = choice.attended
          if process and choice.mode == 'attention' then
            choice:pin(process)
          end
        end,
      }
      list = panel:list {
        id = 'applications',
        label = 'Applications',
        bounds = { x = 20, y = 385, width = 820, height = 300 },
        items = {},
        onChange = function(id: string): ()
          local process = currentRows[id]
          if process == nil or process.dead or not childContext:active() then
            return
          end
          local found = false
          for _, current in lunette.processes() do
            if current == process and not current.dead then
              found = true
              break
            end
          end
          if found then
            choice:pin(process)
          end
        end,
      }
      responseChoice = panel:choice {
        id = 'response',
        label = 'Response',
        bounds = { x = 20, y = 705, width = 400, height = 224 },
        items = presets,
        onChange = function(id: string): ()
          local value = tonumber(id)
          if value then
            choice:setResponse(value)
          end
        end,
      }
      motionChoice = panel:choice {
        id = 'motion',
        label = 'Motion',
        bounds = { x = 440, y = 705, width = 400, height = 224 },
        items = presets,
        onChange = function(id: string): ()
          local value = tonumber(id)
          if value then
            choice:setMotion(value)
          end
        end,
      }
      diagnosticChoice = panel:choice {
        id = 'diagnostic',
        label = 'Diagnostic view',
        bounds = { x = 20, y = 1100, width = 820, height = 260 },
        items = diagnosticItems,
        onChange = function(id: string): ()
          if
            id == 'none'
            or id == 'direction'
            or id == 'coordinates'
            or id == 'cells'
            or id == 'density'
            or id == 'field'
          then
            choice:setDiagnostic(id)
          end
        end,
      }
      panel:region {
        id = 'status',
        label = 'Source status',
        bounds = { x = 20, y = 945, width = 820, height = 140 },
        draw = function(pass: Pass, visual: ui.Visual, _default: ui.Renderer): ()
          local style = visual.theme
          local scale = style.fontSize / style.font:getHeight()
          pass:setColor(style.foreground)
          -- Glyphs are y-up while the panel's logical coordinates are y-down, so the text turns half about x.
          pass:text(
            statusText,
            visual.bounds.x,
            visual.bounds.y,
            0,
            scale,
            math.pi,
            1,
            0,
            0,
            visual.bounds.width / scale,
            'left',
            'top'
          )
        end,
      }
      refresh = function(): ()
        if not live or panel.dead then
          return
        end
        enableChoice:setSelected(if renderer.enabled() then 'on' else 'off')
        reactiveChoice:setSelected(if choice.reactive then 'on' else 'off')
        sourceChoice:setSelected(choice.mode)
        responseChoice:setSelected(selectedPreset(choice.response))
        motionChoice:setSelected(selectedPreset(choice.motion))
        diagnosticChoice:setSelected(choice.diagnostic)
        pinButton:setEnabled(choice.mode == 'attention' and choice.attended ~= nil and not choice.attended.dead)
        local items: { ui.Item } = {}
        local retained: { RowToken } = {}
        currentRows = {}
        local selected: string? = nil
        for _, row in controls.rows(choice, lunette.processes(), lunette.windows()) do
          local token = ''
          -- Fresh userdata compare by process identity, but table keys use raw userdata identity.
          for _, previous in rowTokens do
            if previous.process == row.process then
              token = previous.token
              break
            end
          end
          if token == '' then
            rowSerial += 1
            token = 'application-' .. tostring(rowSerial)
          end
          retained[#retained + 1] = { token = token, process = row.process }
          currentRows[token] = row.process
          items[#items + 1] = { id = token, label = row.label }
          if choice.mode == 'application' and choice.pinned == row.process then
            selected = token
          end
        end
        rowTokens = retained
        local different = #items ~= #shownItems
        for index, item in items do
          local previous = shownItems[index]
          if previous == nil or previous.id ~= item.id or previous.label ~= item.label then
            different = true
            break
          end
        end
        if different then
          shownItems = items
          list:setItems(items)
        end
        list:setSelected(selected)
        statusText = choice:status()
        if not choice.attentionAvailable then
          statusText ..= '\nAttention unavailable: frame, panels, or surfaces provider is missing'
        elseif choice.mode == 'attention' then
          statusText ..= '\nAttention pauses while this panel is open'
        end
      end
      childContext:effect(function(): () -> ()
        return function(): ()
          live = false
          if choice.frozen then
            choice.revision += 1
          end
          choice.frozen = false
          panel:destroy()
        end
      end)
      registration = menus:register(childContext, {
        id = 'desktop/backdrop/open',
        label = 'Backdrop',
        group = 'Appearance',
        order = 100,
        run = function(): ()
          setVisible(not visible)
        end,
      })
      frames:onUpdate(childContext, {
        phase = 'overlay',
        run = function(): ()
          if visible then
            refresh()
          end
        end,
      })
      frames:onDraw(childContext, {
        phase = 'overlay',
        run = function(pass: Pass): ()
          if live then
            panel:draw(pass)
          end
        end,
      })
      childContext:on {
        event = lunette.onWindowOpened,
        run = function(_event: lunette.WindowOpenedEvent): ()
          if visible then
            refresh()
          end
        end,
      }
      refresh()
    end,
  }
  context:child(child.definition)
end

selectedPreset = function(value: number): string
  local nearest, distance = '0', math.huge
  for _, item in presets do
    local number = tonumber(item.id)
    if number and math.abs(number - value) < distance then
      nearest, distance = item.id, math.abs(number - value)
    end
  end
  return nearest
end

rowState = function(state: audio.State?, audioAvailable: boolean): string
  if state then
    if state.kind == 'active' then
      return if state.provenance == 'application-metadata' then ' · active (application metadata)' else ' · active'
    elseif state.kind == 'idle' then
      return ' · silent'
    elseif state.kind == 'unavailable' then
      return ' · unavailable (' .. state.reason .. ')'
    else
      return ' · ' .. state.kind
    end
  end
  return if audioAvailable then ' · no audio stream' else ' · audio provider unavailable'
end

return controls

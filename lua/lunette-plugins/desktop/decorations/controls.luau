-- Owns titlebar buttons through the neutral UI service; the remaining bar stays a drag surface.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local panels = require '@lunette-contracts/panels'
local ui = require '@lunette-contracts/ui'
local config = require './config'

export type Layout = { read close: number, read restart: number, read select: number, read width: number }
local controls = {}

function controls.layout(panel: panels.Panel, style: config.Style): Layout
  local close = math.min(panel.width, style.barHeight)
  local remaining = panel.width - close
  local restart = if panel.kind == 'monitor' then math.min(remaining / 3, style.barHeight * 3) else 0
  local select = if panel.kind == 'monitor' and not panel.source.directCapture
    then math.min(remaining / 3, style.barHeight * 4)
    else 0
  return { close = close, restart = restart, select = select, width = close + restart + select }
end

function controls.definition(style: config.Style): plugin.Definition<config.Config>
  return plugin.consumer<<config.Config, config.Settings>>({
    name = 'desktop/decorations/controls',
    schema = config.schema,
    requires = { frame = frame.capability, panels = panels.capability, ui = ui.capability },
    init = function(context: plugin.Context, _settings: config.Settings): ()
      local frames: frame.Service = context:require(frame.capability)
      local registry: panels.Service = context:require(panels.capability)
      local widgets: ui.Service = context:require(ui.capability)
      type Entry = {
        panel: ui.Panel,
        close: ui.Button,
        restart: ui.Button?,
        selection: ui.Button?,
        label: string,
        width: number,
        height: number,
      }
      local entries: { [panels.Panel]: Entry } = {}
      local refusal: string? = nil
      local refresh: () -> ()
      refresh = function(): ()
        local state = lunette.monitorSelection()
        local label = if state.state == 'pending'
          then 'Waiting for permission'
          else if state.state == 'failed' then 'Retry selection' else 'Select monitors'
        local message = state.message or refusal
        if message and state.state ~= 'pending' then
          label ..= ': ' .. message
        end
        local live: { [panels.Panel]: boolean } = {}
        for _, source in registry:all() do
          if source.dead or source.source.dead or source.chrome then
            continue
          end
          live[source] = true
          local layout = controls.layout(source, style)
          local identity = source.kind .. '/' .. source.source.id
          local entry: Entry? = entries[source]
          if not entry then
            local toolbar = widgets:newPanel(context, {
              name = 'desktop/decorations/' .. source.kind .. '/' .. source.source.id,
              width = layout.width,
              height = style.barHeight,
              logicalWidth = layout.width * 1000,
              logicalHeight = style.barHeight * 1000,
              visible = false,
              grabTarget = source,
              theme = { fontSize = style.barHeight * 1000 * 0.4, padding = 3 },
            })
            local close = toolbar:button(context, {
              id = 'close/' .. identity,
              label = 'X',
              bounds = { x = 0, y = 0, width = 1, height = 1 },
              onActivate = function(): ()
                if context:active() and not source.dead and not source.source.dead and not source:close(context) then
                  error('panel close: request was refused for ' .. tostring(source.source.id), 0)
                end
              end,
            })
            local created: Entry = {
              panel = toolbar,
              close = close,
              restart = nil,
              selection = nil,
              label = '',
              width = 0,
              height = 0,
            }
            entry = created
            entries[source] = created
            local described: panels.Panel = source
            if described.kind == 'monitor' then
              local monitor = described.source
              created.restart = toolbar:button(context, {
                id = 'restart/' .. identity,
                label = 'Restart mirror',
                bounds = { x = 0, y = 0, width = 1, height = 1 },
                onActivate = function(): ()
                  if context:active() and not source.dead and not monitor.dead then
                    monitor:dismiss()
                    if not monitor:mirror() then
                      error('monitor capture: restart was refused for ' .. monitor.name, 0)
                    end
                  end
                end,
              })
            end
          end
          assert(entry ~= nil)
          local selectable: panels.Panel = source
          local canSelect = selectable.kind == 'monitor' and not selectable.source.directCapture
          if not canSelect and entry.selection then
            entry.selection:destroy()
            entry.selection = nil
            entry.label = ''
          end
          local selectionChanged = canSelect and (entry.label ~= label or entry.selection == nil)
          if selectionChanged then
            if entry.selection then
              entry.selection:destroy()
            end
            entry.selection = entry.panel:button(context, {
              id = 'select/' .. identity,
              label = label,
              bounds = { x = 0, y = 0, width = 1, height = 1 },
              onActivate = function(): ()
                if context:active() and not source.dead and not source.source.dead then
                  local accepted, reason = lunette.selectMonitors()
                  refusal = if accepted then nil else reason
                  refresh()
                end
              end,
            })
            entry.label = label
          end
          local resized = entry.width ~= layout.width or entry.height ~= style.barHeight
          if resized then
            entry.panel:setSize(layout.width, style.barHeight, layout.width * 1000, style.barHeight * 1000)
            entry.width, entry.height = layout.width, style.barHeight
            entry.close:setBounds {
              x = (layout.restart + layout.select) * 1000,
              y = 0,
              width = layout.close * 1000,
              height = style.barHeight * 1000,
            }
            if entry.restart then
              entry.restart:setBounds { x = 0, y = 0, width = layout.restart * 1000, height = style.barHeight * 1000 }
            end
          end
          if entry.selection then
            if resized or selectionChanged then
              entry.selection:setBounds {
                x = layout.restart * 1000,
                y = 0,
                width = layout.select * 1000,
                height = style.barHeight * 1000,
              }
            end
            entry.selection:setEnabled(state.state ~= 'pending')
          end
          entry.panel:setPose(
            lovr.math.newMat4(source.pose):translate(
              source.width / 2 - layout.width / 2,
              source.height / 2 + style.margin + style.barHeight / 2,
              0.001
            )
          )
          entry.panel:setVisible(not source.hidden)
        end
        for source, entry in entries do
          if not live[source] then
            entries[source] = nil
            entry.panel:destroy()
          end
        end
      end
      refresh()
      frames:onUpdate(context, {
        phase = 'scene',
        run = function(_dt: number): ()
          refresh()
        end,
      })
      frames:onDraw(context, {
        phase = 'scene',
        run = function(pass: Pass): ()
          for _, entry in entries do
            entry.panel:draw(pass)
          end
        end,
      })
    end,
  }).definition
end

return controls

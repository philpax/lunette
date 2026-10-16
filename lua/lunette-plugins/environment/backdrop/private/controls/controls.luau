-- An optional VR panel exposes all backdrop choices without physical keyboard input.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local uiHost = require '@lunette-contracts/ui-host'
local uiComponents = require '@lunette-contracts/ui-components'
local menu = require '@lunette-contracts/menu'
local ui = require '@lunette-plugins/ui/react'
local selection = require '../selection/selection'
local stores = require './stores'
local component = require './component'

local controls = {}
export type Renderer = stores.Renderer

controls.PANEL = 'desktop/backdrop/controls'

local present: (lunette.Process) -> boolean

function controls.attach(context: plugin.Context, choice: selection.State, renderer: Renderer): ()
  local child = plugin.consumer<<{}, {}>> {
    name = 'desktop/backdrop/controls',
    requires = { frame.capability, uiHost.capability, uiComponents.capability, menu.capability },
    init = function(childContext: plugin.Context, _settings: {}): ()
      local frames: frame.Service = childContext:require(frame.capability)
      local host: uiHost.Service = childContext:require(uiHost.capability)
      local components: uiComponents.Service = childContext:require(uiComponents.capability)
      local menus: menu.Service = childContext:require(menu.capability)
      local published = stores.new(choice, renderer)
      local registration: menu.Registration? = nil
      local visible, live = false, true
      local panel = host:newPanel(childContext, {
        name = controls.PANEL,
        pose = lovr.math.newMat4():translate(0, 1.35, -0.8),
        width = component.WIDTH,
        height = 1,
        size = 'content',
        grabbable = true,
      })
      panel:setVisible(false)
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
        published.refresh()
      end
      -- Each request refreshes the stores at once, so the panel shows its result at the next commit.
      local function apply(change: () -> ()): ()
        if live and childContext:active() then
          change()
          published.refresh()
        end
      end
      local actions: component.Actions = table.freeze {
        setEnabled = function(enabled: boolean): ()
          apply(function(): ()
            renderer.setEnabled(enabled)
          end)
        end,
        setReactive = function(reactive: boolean): ()
          apply(function(): ()
            choice:setReactive(reactive)
          end)
        end,
        setMode = function(mode: selection.Mode): ()
          apply(function(): ()
            choice:setMode(mode)
          end)
        end,
        pinAttended = function(): ()
          apply(function(): ()
            local process = choice.attended
            if process and choice.mode == 'attention' then
              choice:pin(process)
            end
          end)
        end,
        -- A row's process may have exited or left the enumeration since the row was drawn.
        pin = function(token: string): ()
          apply(function(): ()
            local process = published.process(token)
            if process and not process.dead and present(process) then
              choice:pin(process)
            end
          end)
        end,
        setResponse = function(value: number): ()
          apply(function(): ()
            choice:setResponse(value)
          end)
        end,
        setMotion = function(value: number): ()
          apply(function(): ()
            choice:setMotion(value)
          end)
        end,
        setDiagnostic = function(diagnostic: selection.Diagnostic): ()
          apply(function(): ()
            choice:setDiagnostic(diagnostic)
          end)
        end,
        close = function(): ()
          setVisible(false)
        end,
      }
      local mounted = ui.mount(
        panel,
        component.BackdropControls {
          settings = published.settings,
          applications = published.applications,
          actions = actions,
        },
        { components = components, owner = childContext }
      )
      childContext:effect(function(): () -> ()
        return function(): ()
          live = false
          if choice.frozen then
            choice.revision += 1
          end
          choice.frozen = false
          mounted:unmount()
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
      -- Sampling runs before the host's commit in the scene phase, so a change shows in the same frame.
      frames:onUpdate(childContext, {
        phase = 'scene',
        order = -200,
        run = function(): ()
          if visible then
            published.refresh()
          end
        end,
      })
    end,
  }
  context:child(child.definition)
end

-- Native enumerations return fresh handles, so presence compares process identity rather than indexing.
present = function(process: lunette.Process): boolean
  for _, current in lunette.processes() do
    if current == process and not current.dead then
      return true
    end
  end
  return false
end

return controls

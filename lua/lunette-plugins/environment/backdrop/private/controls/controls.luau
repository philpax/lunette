-- An optional VR panel exposes all backdrop choices without physical keyboard input.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local uiHost = require '@lunette-contracts/ui-host'
local uiComponents = require '@lunette-contracts/ui-components'
local menu = require '@lunette-contracts/menu'
local ui = require '@lunette-plugins/ui/react'
local toggle = require '@lunette-plugins/menu/toggle'
local selection = require '../selection/selection'
local stores = require './stores'
local component = require './component'
local kinds = require '../visualisation/kinds'
local scene = require '../visualisation/scene'
local model = require '../rendering/model'

local controls = {}
export type Renderer = stores.Renderer
-- What the panel's views draw from, apart from the history the panel keeps itself.
export type View = {
  read observed: scene.Observed,
  read palette: scene.Palette,
  read miniature: (Pass, model.Frame, number, number?, number) -> (),
  read sectors: number,
  read hold: number,
  -- Whether the panel opens at start, as it was left in the last session.
  read visible: boolean,
}

controls.PANEL = 'desktop/backdrop/controls'

local present: (lunette.Process) -> boolean

function controls.attach(context: plugin.Context, choice: selection.State, renderer: Renderer, view: View): ()
  local child = plugin.consumer<<{}, {}>> {
    name = 'desktop/backdrop/controls',
    requires = { frame.capability, uiHost.capability, uiComponents.capability, menu.capability },
    init = function(childContext: plugin.Context, _settings: {}): ()
      local frames: frame.Service = childContext:require(frame.capability)
      local host: uiHost.Service = childContext:require(uiHost.capability)
      local components: uiComponents.Service = childContext:require(uiComponents.capability)
      local menus: menu.Service = childContext:require(menu.capability)
      local published = stores.new(choice, renderer)
      local history: { scene.Row } = {}
      local sampled = 0
      local views = kinds.register(host, childContext, {
        observed = view.observed,
        history = history,
        palette = view.palette,
        miniature = view.miniature,
        sectors = view.sectors,
        hold = view.hold,
      })
      local summary = ui.store(scene.summary(view.observed))
      local opener: toggle.Toggle? = nil
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
        published.refresh()
      end
      -- Each request refreshes the stores at once, so the panel shows its result at the next commit, and saves the
      -- configuration fields it changed through the backdrop entry's own context.
      local function apply(change: () -> (), saved: { [string]: unknown }?): ()
        if live and childContext:active() then
          change()
          published.refresh()
          if saved then
            context:save(saved)
          end
        end
      end
      local actions: component.Actions = table.freeze {
        setEnabled = function(enabled: boolean): ()
          apply(function(): ()
            renderer.setEnabled(enabled)
          end, { enabled = enabled })
        end,
        setReactive = function(reactive: boolean): ()
          apply(function(): ()
            choice:setReactive(reactive)
          end, { reactive = reactive })
        end,
        setMode = function(mode: selection.Mode): ()
          -- A pinned application is a process, which a later session cannot have, so only the other modes are saved.
          apply(function(): ()
            choice:setMode(mode)
          end, if mode ~= 'application' then { sourceMode = mode } else nil)
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
          end, { response = value })
        end,
        setMotion = function(value: number): ()
          apply(function(): ()
            choice:setMotion(value)
          end, { motion = value })
        end,
        setDiagnostic = function(diagnostic: selection.Diagnostic): ()
          apply(function(): ()
            choice:setDiagnostic(diagnostic)
          end, { diagnostic = diagnostic })
        end,
        close = function(): ()
          if opener then
            opener:set(false)
          end
        end,
      }
      local mounted = ui.mount(
        panel,
        component.BackdropControls {
          settings = published.settings,
          applications = published.applications,
          summary = summary,
          views = views,
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
      -- Opening and closing saves `controlsVisible` through the backdrop entry, so the panel opens at the next start
      -- as it was left.
      opener = toggle.attach(childContext, menus, {
        id = 'desktop/backdrop/open',
        label = 'Backdrop',
        group = 'Appearance',
        visible = view.visible,
        show = function(): ()
          setVisible(true)
        end,
        hide = function(): ()
          setVisible(false)
        end,
        save = function(open: boolean): ()
          context:save { controlsVisible = open }
        end,
      })
      -- Sampling runs before the host's commit in the scene phase, so a change shows in the same frame.
      frames:onUpdate(childContext, {
        phase = 'scene',
        order = -200,
        run = function(dt: number): ()
          if not visible then
            return
          end
          published.refresh()
          -- The skyline samples its history at a fixed rate, so its depth spans the same time at any frame rate.
          sampled += if dt == dt and dt > 0 and dt < math.huge then dt else 0
          if sampled >= scene.ROW_INTERVAL or #history == 0 then
            sampled = math.clamp(sampled - scene.ROW_INTERVAL, 0, scene.ROW_INTERVAL)
            scene.push(history, scene.row(view.observed.frame))
          end
          local next = scene.summary(view.observed)
          if not scene.sameSummary(summary:get(), next) then
            summary:set(next)
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

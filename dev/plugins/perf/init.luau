-- Shows frame performance on a panel that the wrist menu opens, and controls foveated rendering. Sampling and GPU
-- timing run only while the panel is open.
local plugin = require '@lunette-plugin'
local schema = require '@lunette-plugin/schema'
local uiHost = require '@lunette-contracts/ui-host'
local uiComponents = require '@lunette-contracts/ui-components'
local menu = require '@lunette-contracts/menu'
local frame = require '@lunette-contracts/frame'
local toggle = require '@lunette-plugins/menu/toggle'
local ui = require '@lunette-plugins/ui/react'
local foveation = require '@self/foveation'
local metrics = require '@self/metrics'
local readout = require '@self/readout'
local panel = require '@self/panel'
local sparkline = require '@self/sparkline'

-- 240 samples span four seconds at 60 Hz and two at 120 Hz: long enough to hold an intermittent hitch in the maximum,
-- and short enough that the average follows a change in load within seconds.
local HISTORY = 240
-- Seconds between panel refreshes. Redrawing the readout every frame would add the panel's own cost to what it shows.
local REFRESH = 0.25

-- Whether the panel is open, the foveation level, and whether the density overlay is shown. Each is saved when it
-- changes, so the next start restores it.
local descriptor = schema.object {
  visible = schema.default(schema.boolean())(false),
  foveation = schema.default(schema.enum<<foveation.Level>>(foveation.LEVELS)) 'low',
  overlay = schema.default(schema.boolean())(false),
}
export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

-- Enables GPU timing for as long as the effect holds, restoring whether it was enabled before.
local function timing(context: plugin.Context): plugin.Effect
  return context:effect(function(): () -> ()
    local enabled = lovr.graphics.isTimingEnabled()
    lovr.graphics.setTimingEnabled(true)
    return function(): ()
      lovr.graphics.setTimingEnabled(enabled)
    end
  end)
end

local function label(pass: Pass): string?
  return pass:getLabel()
end

-- Samples the headset's frame timing every frame and publishes a snapshot each refresh. The graphics timing is read
-- only at a refresh, because reading it waits for the GPU to finish the last submission.
local function sample(
  context: plugin.Context,
  frames: frame.Service,
  store: ui.WritableStore<readout.Snapshot>
): plugin.Effect
  local state = metrics.new(HISTORY)
  local passes: { metrics.PassTime } = {}
  local elapsed = 0
  return frames:onUpdate(context, {
    phase = 'input',
    run = function(dt: number): ()
      metrics.observe(state, lovr.headset.getFrameTiming())
      elapsed += dt
      if elapsed < REFRESH then
        return
      end
      elapsed = 0
      local results = lovr.graphics.getTiming()
      if results then
        passes = metrics.passes(results, label)
      end
      store:set(readout.snapshot(state, passes))
    end,
  })
end

return plugin.consumer<<Config, Settings>> {
  name = 'dev/perf',
  schema = descriptor,
  requires = { uiHost.capability, uiComponents.capability, menu.capability, frame.capability },
  init = function(context: plugin.Context, settings: Settings): ()
    local host = context:require(uiHost.capability)
    local components = context:require(uiComponents.capability)
    local frames = context:require(frame.capability)
    local controller = foveation.attach(context, foveation.headset(), {
      level = settings.foveation,
      overlay = settings.overlay,
    })
    local graph = sparkline.register(host, context)
    local open: { read panel: uiHost.Panel, read effects: { plugin.Effect } }? = nil
    local performance: toggle.Toggle
    performance = toggle.attach(context, context:require(menu.capability), {
      id = 'dev/perf/open',
      label = 'Performance',
      group = 'Development',
      visible = settings.visible,
      show = function(): ()
        local store = ui.store(readout.snapshot(metrics.new(HISTORY), {}))
        local effects = { timing(context), sample(context, frames, store) }
        local shown = host:newPanel(context, { name = 'Performance', width = 0.5, height = 0.5 })
        ui.mount(
          shown,
          panel.Performance {
            snapshot = store,
            foveation = controller,
            sparkline = graph,
            capacity = HISTORY,
            onClose = function(): ()
              performance:set(false)
            end,
          },
          { components = components, owner = context }
        )
        open = { panel = shown, effects = effects }
      end,
      hide = function(): ()
        local held = open
        if held then
          open = nil
          for _, effect in held.effects do
            effect:dispose()
          end
          held.panel:destroy()
        end
      end,
    })
  end,
}

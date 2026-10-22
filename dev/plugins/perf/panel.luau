-- The performance panel: foveation controls, a frame-interval graph, rolling frame times, window counts, and GPU time
-- by pass.
local ui = require '@lunette-plugins/ui/react'
local uiHost = require '@lunette-contracts/ui-host'
local foveation = require './foveation'
local readout = require './readout'

local panel = {}

export type Props = {
  read snapshot: ui.Store<readout.Snapshot>,
  read foveation: foveation.Controller,
  read sparkline: uiHost.Constructor,
  -- The number of samples the graph's full width holds.
  read capacity: number,
  read onClose: () -> (),
}

local LEVEL_OPTIONS = {
  { id = 'none', label = 'Off' },
  { id = 'low', label = 'Low' },
  { id = 'medium', label = 'Medium' },
  { id = 'high', label = 'High' },
}

local TIME_COLUMNS = {
  { id = 'metric', label = 'Metric' },
  { id = 'current', label = 'Current' },
  { id = 'average', label = 'Average' },
  { id = 'maximum', label = 'Maximum' },
}

local PASS_COLUMNS = { { id = 'pass', label = 'Pass' }, { id = 'gpu', label = 'GPU time' } }

panel.Performance = ui.component('Performance', function(props: Props): ui.Child
  local c = ui.useComponents()
  local snapshot = ui.useStore(props.snapshot)
  local status, setStatus = ui.useState(props.foveation:status())
  local counts = {}
  for index, line in snapshot.counts do
    counts[index] = c.Text { key = `count-{index}`, text = line, style = 'caption' }
  end
  return c.Panel {
    title = 'Performance',
    onClose = props.onClose,
    c.Body {
      key = 'body',
      grow = 1,
      c.ScrollView {
        key = 'scroll',
        grow = 1,
        bleed = true,
        c.Column {
          key = 'content',
          gap = 'sm',
          c.Segmented {
            key = 'foveation',
            value = status.level,
            options = LEVEL_OPTIONS,
            onChange = function(next: foveation.Level): ()
              setStatus(props.foveation:setLevel(next))
            end,
          },
          if status.levelUnavailable
            then c.Text {
              key = 'foveation-unavailable',
              text = 'The headset does not support this foveation level.',
              style = 'caption',
              color = 'muted',
            }
            else nil,
          c.Toggle {
            key = 'overlay',
            label = 'Density overlay',
            detail = if status.overlayUnavailable then 'The headset does not support the overlay.' else nil,
            value = status.overlay,
            onChange = function(next: boolean): ()
              setStatus(props.foveation:setOverlay(next))
            end,
          },
          props.sparkline { key = 'graph', values = snapshot.intervals, capacity = props.capacity },
          c.Table { key = 'times', columns = TIME_COLUMNS, rows = snapshot.times },
          counts,
          if #snapshot.passes > 0
            then c.Table { key = 'passes', columns = PASS_COLUMNS, rows = snapshot.passes }
            else c.Text { key = 'passes', text = 'No GPU timing yet.', style = 'caption', color = 'muted' },
        },
      },
    },
  }
end)

return panel

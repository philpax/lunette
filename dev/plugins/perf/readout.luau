-- Formats rolling metrics as table rows and summary lines for the panel.
local history = require './history'
local metrics = require './metrics'

local readout = {}

export type Row = { read id: string, read cells: { read [number]: string } }

function readout.milliseconds(seconds: number): string
  return string.format('%.2f ms', seconds * 1000)
end

-- Current, average, and maximum of each timed series that has samples.
function readout.times(state: metrics.Metrics): { Row }
  local rows: { Row } = {}
  local function add(id: string, label: string, ring: history.History): ()
    local latest, mean, maximum = history.latest(ring), history.mean(ring), history.maximum(ring)
    if latest and mean and maximum then
      table.insert(rows, {
        id = id,
        cells = { label, readout.milliseconds(latest), readout.milliseconds(mean), readout.milliseconds(maximum) },
      })
    end
  end
  add('interval', 'Frame interval', state.interval)
  add('work', 'Work', state.work)
  add('prediction', 'Prediction', state.prediction)
  if state.compositor then
    add('compositor-gpu', 'Compositor GPU', state.gpu)
    add('compositor-cpu', 'Compositor CPU', state.cpu)
  end
  return rows
end

-- Counts over the window, which a single frame's value would hide.
function readout.counts(state: metrics.Metrics): { string }
  local frames = history.count(state.interval)
  if frames == 0 then
    return { 'No frame timing yet.' }
  end
  local lines = {
    string.format('Skipped refreshes: %d in the last %d frames.', history.sum(state.skipped), frames),
  }
  if state.compositor then
    table.insert(
      lines,
      string.format(
        'Dropped: %d, mispresented: %d in the last %d compositor frames.',
        history.sum(state.dropped),
        history.sum(state.mispresented),
        history.count(state.dropped)
      )
    )
    table.insert(lines, if state.reprojecting then 'SteamVR is reprojecting.' else 'SteamVR is not reprojecting.')
  end
  return lines
end

function readout.passes(passes: { metrics.PassTime }): { Row }
  local rows: { Row } = {}
  for _, pass in passes do
    table.insert(rows, { id = pass.label, cells = { pass.label, readout.milliseconds(pass.duration) } })
  end
  return rows
end

-- What one refresh of the panel shows. Each refresh builds a new table, so a store holding it notifies on every one.
export type Snapshot = {
  read times: { Row },
  read counts: { string },
  read passes: { Row },
  read intervals: { number },
}

function readout.snapshot(state: metrics.Metrics, passes: { metrics.PassTime }): Snapshot
  return table.freeze {
    times = readout.times(state),
    counts = readout.counts(state),
    passes = readout.passes(passes),
    intervals = history.values(state.interval),
  }
end

return readout

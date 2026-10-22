-- Rolling frame metrics from the headset's frame timing, and GPU time grouped by pass label from the graphics timing.
local history = require './history'

local metrics = {}

-- The shapes of `lovr.headset.getFrameTiming`, in seconds and counts.
export type Compositor = {
  read frame: number,
  read gpu: number,
  read cpu: number,
  read presents: number,
  read mispresented: number,
  read dropped: number,
  read reprojecting: boolean,
}

export type FrameTiming = {
  read interval: number,
  read work: number,
  read prediction: number,
  read skipped: number,
  read compositor: Compositor?,
}

-- Application series take one sample per observed frame; compositor series take one per compositor frame, since the
-- runtime reports the same compositor frame again until it composes another.
export type Metrics = {
  read interval: history.History,
  read work: history.History,
  read prediction: history.History,
  read skipped: history.History,
  read gpu: history.History,
  read cpu: history.History,
  read dropped: history.History,
  read mispresented: history.History,
  compositorFrame: number?,
  -- Whether the latest timing carried compositor statistics, and whether that compositor frame was reprojected.
  compositor: boolean,
  reprojecting: boolean,
}

export type PassTime = { read label: string, read duration: number }

-- The label of passes that have none.
metrics.UNLABELLED = 'unlabelled'

function metrics.new(capacity: number): Metrics
  return {
    interval = history.new(capacity),
    work = history.new(capacity),
    prediction = history.new(capacity),
    skipped = history.new(capacity),
    gpu = history.new(capacity),
    cpu = history.new(capacity),
    dropped = history.new(capacity),
    mispresented = history.new(capacity),
    compositorFrame = nil,
    compositor = false,
    reprojecting = false,
  }
end

-- Records one frame's timing. Nil, which the headset answers before it has timed a frame, records nothing.
function metrics.observe(state: Metrics, timing: FrameTiming?): ()
  if timing == nil then
    return
  end
  history.push(state.interval, timing.interval)
  history.push(state.work, timing.work)
  history.push(state.prediction, timing.prediction)
  history.push(state.skipped, timing.skipped)
  local compositor = timing.compositor
  state.compositor = compositor ~= nil
  if compositor == nil then
    state.reprojecting = false
    return
  end
  state.reprojecting = compositor.reprojecting
  if compositor.frame == state.compositorFrame then
    return
  end
  state.compositorFrame = compositor.frame
  history.push(state.gpu, compositor.gpu)
  history.push(state.cpu, compositor.cpu)
  history.push(state.dropped, compositor.dropped)
  history.push(state.mispresented, compositor.mispresented)
end

-- Sums GPU durations by label, longest first, then by label. Passes sharing a label, such as one per frame of the
-- same view, add together.
function metrics.passes<K>(timing: { read [K]: { read duration: number } }, label: (K) -> string?): { PassTime }
  local totals: { [string]: number } = {}
  for pass, entry in timing do
    local name = label(pass) or metrics.UNLABELLED
    totals[name] = (totals[name] or 0) + entry.duration
  end
  local list: { PassTime } = {}
  for name, duration in totals do
    table.insert(list, { label = name, duration = duration })
  end
  table.sort(list, function(a: PassTime, b: PassTime): boolean
    if a.duration ~= b.duration then
      return a.duration > b.duration
    end
    return a.label < b.label
  end)
  return list
end

return metrics

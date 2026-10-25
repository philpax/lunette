-- Stores a bounded capture of coherent host timing records and exports the versioned development CSV wire.
local native = require '@lunette'
local capture = {}

type Cell = number | boolean | string
local fields: { { name: string, readValue: (native.FrameTiming) -> Cell? } } = {
  {
    name = 'sequence',
    readValue = function(r: native.FrameTiming): Cell?
      return r.sequence
    end,
  },
  {
    name = 'syncTime',
    readValue = function(r: native.FrameTiming): Cell?
      return r.syncTime
    end,
  },
  {
    name = 'sync',
    readValue = function(r: native.FrameTiming): Cell?
      return r.sync
    end,
  },
  {
    name = 'interval',
    readValue = function(r: native.FrameTiming): Cell?
      return r.interval
    end,
  },
  {
    name = 'update',
    readValue = function(r: native.FrameTiming): Cell?
      return r.update
    end,
  },
  {
    name = 'draw',
    readValue = function(r: native.FrameTiming): Cell?
      return r.draw
    end,
  },
  {
    name = 'graphicsSubmit',
    readValue = function(r: native.FrameTiming): Cell?
      return r.graphicsSubmit
    end,
  },
  {
    name = 'headsetSubmit',
    readValue = function(r: native.FrameTiming): Cell?
      return r.headsetSubmit
    end,
  },
  {
    name = 'present',
    readValue = function(r: native.FrameTiming): Cell?
      return r.present
    end,
  },
  {
    name = 'gc',
    readValue = function(r: native.FrameTiming): Cell?
      return r.gc
    end,
  },
  {
    name = 'observer',
    readValue = function(r: native.FrameTiming): Cell?
      return r.observer
    end,
  },
  {
    name = 'heapSync',
    readValue = function(r: native.FrameTiming): Cell?
      return r.heapSync
    end,
  },
  {
    name = 'heapUpdate',
    readValue = function(r: native.FrameTiming): Cell?
      return r.heapUpdate
    end,
  },
  {
    name = 'heapDraw',
    readValue = function(r: native.FrameTiming): Cell?
      return r.heapDraw
    end,
  },
  {
    name = 'heapGraphicsSubmit',
    readValue = function(r: native.FrameTiming): Cell?
      return r.heapGraphicsSubmit
    end,
  },
  {
    name = 'heapHeadsetSubmit',
    readValue = function(r: native.FrameTiming): Cell?
      return r.heapHeadsetSubmit
    end,
  },
  {
    name = 'heapPresent',
    readValue = function(r: native.FrameTiming): Cell?
      return r.heapPresent
    end,
  },
  {
    name = 'heapGc',
    readValue = function(r: native.FrameTiming): Cell?
      return r.heapGc
    end,
  },
  {
    name = 'active',
    readValue = function(r: native.FrameTiming): Cell?
      return r.active
    end,
  },
  {
    name = 'visible',
    readValue = function(r: native.FrameTiming): Cell?
      return r.visible
    end,
  },
  {
    name = 'focused',
    readValue = function(r: native.FrameTiming): Cell?
      return r.focused
    end,
  },
  {
    name = 'nativeInterval',
    readValue = function(r: native.FrameTiming): Cell?
      return r.nativeInterval
    end,
  },
  {
    name = 'nativeWork',
    readValue = function(r: native.FrameTiming): Cell?
      return r.nativeWork
    end,
  },
  {
    name = 'skipped',
    readValue = function(r: native.FrameTiming): Cell?
      return r.skipped
    end,
  },
  {
    name = 'refreshRate',
    readValue = function(r: native.FrameTiming): Cell?
      return r.refreshRate
    end,
  },
  {
    name = 'gcBudgetUs',
    readValue = function(r: native.FrameTiming): Cell?
      return r.gcBudgetUs
    end,
  },
  {
    name = 'gpuTiming',
    readValue = function(r: native.FrameTiming): Cell?
      return r.gpuTiming
    end,
  },
  {
    name = 'supersample',
    readValue = function(r: native.FrameTiming): Cell?
      return r.supersample
    end,
  },
  {
    name = 'antialias',
    readValue = function(r: native.FrameTiming): Cell?
      return r.antialias
    end,
  },
  {
    name = 'foveation',
    readValue = function(r: native.FrameTiming): Cell?
      return r.foveation
    end,
  },
  {
    name = 'executionMode',
    readValue = function(r: native.FrameTiming): Cell?
      return r.executionMode
    end,
  },
  {
    name = 'betweenFrames',
    readValue = function(r: native.FrameTiming): Cell?
      return r.betweenFrames
    end,
  },
  {
    name = 'gcSteps',
    readValue = function(r: native.FrameTiming): Cell?
      return r.gcSteps
    end,
  },
  {
    name = 'gcCycleCompleted',
    readValue = function(r: native.FrameTiming): Cell?
      return r.gcCycleCompleted
    end,
  },
  {
    name = 'gcOverrun',
    readValue = function(r: native.FrameTiming): Cell?
      return r.gcOverrun
    end,
  },
}
local header = { 'formatVersion' }
for _, field in fields do
  table.insert(header, if string.sub(field.name, 1, 4) == 'heap' then field.name .. 'KiB' else field.name)
end
export type Record = native.FrameTiming
export type State = {
  rows: { { Cell } },
  count: number,
  duration: number,
  started: number?,
  status: 'capturing' | 'complete' | 'stopped' | 'cancelled',
}

function capture.new(capacity: number, duration: number): State
  assert(capacity >= 1 and capacity <= 10000 and capacity % 1 == 0, 'frame trace: capacity must be 1 to 10000')
  assert(duration > 0 and duration <= 120, 'frame trace: duration must be finite and at most 120 seconds')
  local rows: { { Cell } } = table.create(capacity) :: { { Cell } }
  for index = 1, capacity do
    rows[index] = table.create(#fields, '') :: { Cell }
  end
  return { rows = rows, count = 0, duration = duration, started = nil, status = 'capturing' }
end

function capture.observe(state: State, record: Record): ()
  if state.status ~= 'capturing' then
    return
  end
  local sync = record.syncTime
  assert(type(sync) == 'number' and sync == sync and math.abs(sync) < math.huge, 'frame trace: invalid syncTime')
  if state.started == nil then
    state.started = sync
  end
  local row = state.rows[state.count + 1]
  for index, field in fields do
    local value = field.readValue(record)
    if type(value) == 'number' then
      assert(value == value and math.abs(value) < math.huge, 'frame trace: invalid ' .. field.name)
    end
    row[index] = if value == nil then '' else value
  end
  state.count += 1
  if state.count == #state.rows or sync - assert(state.started) >= state.duration then
    state.status = 'complete'
  end
end

function capture.stop(state: State): ()
  if state.status == 'capturing' then
    state.status = 'stopped'
  end
end

function capture.cancel(state: State): ()
  state.status = 'cancelled'
  state.count = 0
end

local function cell(value: Cell): string
  local text = tostring(value)
  if string.find(text, '[,\r\n"]') then
    return '"' .. string.gsub(text, '"', '""') .. '"'
  end
  return text
end

function capture.csv(state: State): string
  assert(state.status == 'complete' or state.status == 'stopped', 'frame trace: no completed capture to export')
  local lines = table.create(state.count + 1)
  lines[1] = table.concat(header, ',')
  local values = table.create(#fields + 1, '')
  values[1] = '1'
  for index = 1, state.count do
    for column, value in state.rows[index] do
      values[column + 1] = cell(value)
    end
    lines[index + 1] = table.concat(values, ',')
  end
  return table.concat(lines, '\n') .. '\n'
end

return capture

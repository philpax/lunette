-- Host-owned opt-in phase sampling. The boot chunk holds this table; plugins receive only completed records.
local executionMode = ...
local state = { active = false, row = {}, sequence = 0 }
local previousSync = nil
local boundary = nil
local overhead = 0
local syncStarted = nil

local function clock(): number
  return lovr.timer.getTime()
end

function state.begin()
  local started = clock()
  local row = state.row
  table.clear(row)
  state.sequence += 1
  row.sequence = state.sequence
  row.executionMode = executionMode
  row.supersample = state.supersample
  row.antialias = state.antialias
  overhead = clock() - started
  boundary = nil
  syncStarted = if lovr.headset then clock() else nil
end

function state.sync()
  local started = clock()
  local row = state.row
  row.syncTime = started
  row.sync = if syncStarted then started - syncStarted else nil
  row.interval = if previousSync then started - previousSync else nil
  previousSync = started
  row.heapSync = gcinfo()
  if lovr.headset then
    row.active = lovr.headset.isActive()
    row.visible = lovr.headset.isVisible()
    row.focused = lovr.headset.isFocused()
    row.refreshRate = lovr.headset.getRefreshRate()
    local timing = lovr.headset.getFrameTiming()
    if timing then
      row.nativeInterval = timing.interval
      row.nativeWork = timing.work
      row.skipped = timing.skipped
    end
    local level = lovr.headset.getFoveation()
    row.foveation = level
  end
  if lovr.graphics then
    row.gpuTiming = lovr.graphics.isTimingEnabled()
  end
  overhead += clock() - started
  boundary = clock()
end

function state.before()
  boundary = clock()
end

function state.mark(heap: string, phase: string)
  local started = clock()
  local row = state.row
  if boundary then
    row[phase] = (row[phase] or 0) + started - boundary
  end
  row[heap] = gcinfo()
  overhead += clock() - started
  boundary = clock()
end

function state.collected(gc: number, budget: number)
  local started = clock()
  local row = state.row
  row.gc = gc
  row.gcBudgetUs = budget
  row.heapGc = gcinfo()
  overhead += clock() - started
end

function state.finish(): typeof(state.row)
  state.row.observer = overhead
  return state.row
end

function state.reset()
  previousSync = nil
  boundary = nil
  state.row = {}
end

return state

-- Retains source choices by process handle; unavailable application sources never select the system mix.
local lunette = require '@lunette'
local audio = require '@lunette-contracts/audio'

local selection = {}
export type Mode = 'system' | 'application' | 'attention'
-- A development view of one stage of the overhead sky field; 'none' draws the backdrop normally.
export type Diagnostic = 'none' | 'direction' | 'coordinates' | 'cells' | 'density' | 'field'
export type Settings = {
  read sourceMode: Mode?,
  read reactive: boolean?,
  read response: number?,
  read motion: number?,
  read dwell: number?,
  read diagnostic: Diagnostic?,
}
export type State = {
  mode: Mode,
  pinned: lunette.Process?,
  attended: lunette.Process?,
  reactive: boolean,
  response: number,
  motion: number,
  dwell: number,
  diagnostic: Diagnostic,
  frozen: boolean,
  revision: number,
  audioAvailable: boolean,
  attentionAvailable: boolean,
  audioState: audio.State?,
  processStatuses: { audio.ProcessStatus },
  configured: Settings?,
  read configure: (State, Settings) -> (),
  read setMode: (State, Mode) -> (),
  read pin: (State, lunette.Process) -> boolean,
  read attend: (State, lunette.Process) -> boolean,
  read source: (State) -> audio.Source?,
  read setReactive: (State, boolean) -> (),
  read setResponse: (State, number) -> (),
  read setMotion: (State, number) -> (),
  read setDiagnostic: (State, Diagnostic) -> (),
  read status: (State) -> string,
}
local State = {}
State.__index = State
local changed: (State) -> ()
local bounded: (number) -> number

function selection.new(settings: Settings?): State
  local state: State = setmetatable({
    mode = 'system',
    pinned = nil :: lunette.Process?,
    attended = nil :: lunette.Process?,
    reactive = true,
    response = 1,
    motion = 1,
    dwell = 0.75,
    diagnostic = 'none' :: Diagnostic,
    frozen = false,
    revision = 0,
    audioAvailable = false,
    attentionAvailable = false,
    audioState = nil :: audio.State?,
    processStatuses = {},
    configured = nil :: Settings?,
  }, State)
  state:configure(settings or {})
  return state
end

-- Equal configured values preserve session choices across provider reactivation.
function State.configure(self: State, settings: Settings): ()
  local previous = self.configured
  if previous == nil or previous.sourceMode ~= settings.sourceMode then
    self:setMode(settings.sourceMode or 'system')
  end
  if previous == nil or previous.reactive ~= settings.reactive then
    self:setReactive(settings.reactive ~= false)
  end
  if previous == nil or previous.response ~= settings.response then
    self:setResponse(settings.response or 1)
  end
  if previous == nil or previous.motion ~= settings.motion then
    self:setMotion(settings.motion or 1)
  end
  if previous == nil or previous.diagnostic ~= settings.diagnostic then
    self:setDiagnostic(settings.diagnostic or 'none')
  end
  if previous == nil or previous.dwell ~= settings.dwell then
    local duration = settings.dwell or 0.75
    self.dwell = if duration == duration and duration < math.huge then math.clamp(duration, 0.1, 3) else 0.75
    self.revision += 1
  end
  self.configured = table.freeze {
    dwell = settings.dwell,
    sourceMode = settings.sourceMode,
    reactive = settings.reactive,
    response = settings.response,
    motion = settings.motion,
    diagnostic = settings.diagnostic,
  }
end

function State.setMode(self: State, mode: Mode): ()
  if self.mode ~= mode then
    self.mode = mode
    changed(self)
  end
end

function State.pin(self: State, process: lunette.Process): boolean
  if process.dead then
    return false
  end
  local different = self.pinned ~= process or self.mode ~= 'application'
  self.pinned = process
  self.mode = 'application'
  if different then
    changed(self)
  end
  return true
end

function State.attend(self: State, process: lunette.Process): boolean
  if process.dead or self.mode ~= 'attention' or self.frozen then
    return false
  end
  if self.attended ~= process then
    self.attended = process
    changed(self)
  end
  return true
end

function State.source(self: State): audio.Source?
  if not self.reactive then
    return nil
  end
  if self.mode == 'system' then
    return { kind = 'system' }
  end
  local process = if self.mode == 'application' then self.pinned else self.attended
  -- A dead handle remains the selected identity. The reader reports ended, rather than opening the mix.
  return if process then { kind = 'process', process = process } else nil
end

function State.setReactive(self: State, reactive: boolean): ()
  if self.reactive ~= reactive then
    self.reactive = reactive
    changed(self)
  end
end

function State.setResponse(self: State, response: number): ()
  self.response = bounded(response)
end

function State.setMotion(self: State, motion: number): ()
  self.motion = bounded(motion)
end

function State.setDiagnostic(self: State, diagnostic: Diagnostic): ()
  self.diagnostic = diagnostic
end

function State.status(self: State): string
  if not self.reactive then
    return 'Audio reactivity is off'
  end
  local source = self:source()
  if source == nil then
    return if self.mode == 'attention' then 'Waiting for an attended application' else 'No application is pinned'
  end
  local label = if source.kind == 'system' then 'System mix' else 'Application #' .. tostring(source.process.id)
  local state = self.audioState
  if state and state.kind == 'starting' then
    return label .. ': starting'
  end
  if source.kind == 'process' and source.process.dead then
    return label .. ': ended'
  end
  if not self.audioAvailable then
    return label .. ': audio provider unavailable'
  end
  if state == nil or state.kind == 'starting' then
    return label .. ': starting'
  elseif state.kind == 'active' then
    return label
      .. (if state.provenance == 'application-metadata' then ': active (application metadata)' else ': active')
  elseif state.kind == 'idle' then
    return label .. ': silent'
  elseif state.kind == 'ended' then
    return label .. ': ended'
  else
    return label .. ': unavailable (' .. state.reason .. ')'
  end
end

changed = function(state: State): ()
  state.revision += 1
  state.audioState = nil
end

bounded = function(value: number): number
  return if value == value and math.abs(value) < math.huge then math.clamp(value, 0, 1) else 0
end

return selection

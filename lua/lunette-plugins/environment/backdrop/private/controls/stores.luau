-- Publishes the backdrop's choices and application list as stores for the control panel.
-- Native process, window, and audio state has no change events, so `refresh` samples it and a store changes only
-- when what it shows differs.
local lunette = require '@lunette'
local audio = require '@lunette-contracts/audio'
local vocabulary = require '@lunette-contracts/vocabulary'
local ui = require '@lunette-plugins/ui/react'
local selection = require '../selection/selection'

local stores = {}

export type Renderer = { read enabled: () -> boolean, read setEnabled: (boolean) -> () }

export type Settings = {
  read enabled: boolean,
  read reactive: boolean,
  read mode: selection.Mode,
  read response: number,
  read motion: number,
  read diagnostic: selection.Diagnostic,
  -- Nil when the attended application can be pinned.
  read pinReason: string?,
  read status: string,
  read notice: string?,
}

-- One process as a list row. The process handle is the row's identity; the text never replaces it.
export type Row = {
  read process: lunette.Process,
  read title: string,
  read detail: string,
  read trailing: string,
}

-- A row with a token that is unique for the life of the stores, so a key never moves to another process.
export type Application = Row & { read token: string, read selected: boolean }

export type Stores = {
  read settings: vocabulary.Store<Settings>,
  read applications: vocabulary.Store<{ Application }>,
  read refresh: () -> (),
  -- The process behind a row token, while the row is shown.
  read process: (string) -> lunette.Process?,
}

type RowDetails = { process: lunette.Process, names: { string }, label: string?, state: audio.State? }
type RowToken = { read token: string, read process: lunette.Process }

local settingsOf: (selection.State, Renderer) -> Settings
local sameSettings: (Settings, Settings) -> boolean
local sameApplications: ({ Application }, { Application }) -> boolean
local rowState: (audio.State?, boolean) -> string

function stores.new(choice: selection.State, renderer: Renderer): Stores
  local settings = ui.store(settingsOf(choice, renderer))
  local applications = ui.store({} :: { Application })
  local serial = 0
  local tokens: { RowToken } = {}
  local function refresh(): ()
    local nextSettings = settingsOf(choice, renderer)
    if not sameSettings(settings:get(), nextSettings) then
      settings:set(nextSettings)
    end
    local list: { Application } = {}
    local retained: { RowToken } = {}
    for _, row in stores.rows(choice, lunette.processes(), lunette.windows()) do
      local kept: RowToken? = nil
      -- Fresh userdata compare by process identity, so the search compares rather than indexing by handle.
      for _, previous in tokens do
        if previous.process == row.process then
          kept = previous
          break
        end
      end
      if kept == nil then
        serial += 1
        kept = { token = 'application-' .. tostring(serial), process = row.process }
      end
      local entry = assert(kept)
      retained[#retained + 1] = entry
      list[#list + 1] = {
        token = entry.token,
        process = entry.process,
        title = row.title,
        detail = row.detail,
        trailing = row.trailing,
        selected = choice.mode == 'application' and choice.pinned == row.process,
      }
    end
    tokens = retained
    if not sameApplications(applications:get(), list) then
      applications:set(list)
    end
  end
  local function process(token: string): lunette.Process?
    for _, entry in tokens do
      if entry.token == token then
        return entry.process
      end
    end
    return nil
  end
  return table.freeze { settings = settings, applications = applications, refresh = refresh, process = process }
end

-- Numeric IDs narrow the lookup; exact process equality rejects stale handles and matches fresh wrappers.
function stores.rows(choice: selection.State, processes: { lunette.Process }, windows: { lunette.Window }): { Row }
  local details: { RowDetails } = {}
  local byId: { [number]: { RowDetails } } = {}
  for _, process in processes do
    if process.dead then
      continue
    end
    local entry: RowDetails = { process = process, names = {}, label = nil, state = nil }
    details[#details + 1] = entry
    local candidates = byId[process.id]
    if candidates == nil then
      candidates = {}
      byId[process.id] = candidates
    end
    candidates[#candidates + 1] = entry
  end
  for _, window in windows do
    if window.dead then
      continue
    end
    local process = window.process
    local candidates = if process then byId[process.id] else nil
    if candidates then
      for _, entry in candidates do
        if entry.process == process then
          local title, appId = window.title, window.appId
          local label = if title and title ~= ''
            then title
            elseif appId and appId ~= '' then appId
            else 'Process ' .. tostring(entry.process.id)
          if appId and appId ~= '' and appId ~= label then
            label ..= ' (' .. appId .. ')'
          end
          entry.names[#entry.names + 1] = label
        end
      end
    end
  end
  for _, status in choice.processStatuses do
    local candidates = byId[status.process.id]
    if candidates then
      for _, entry in candidates do
        if entry.process == status.process then
          if entry.label == nil and status.label ~= '' then
            entry.label = status.label
          end
          if entry.state == nil then
            entry.state = status.state
          end
        end
      end
    end
  end
  local rows: { Row } = {}
  for _, entry in details do
    local process = entry.process
    rows[#rows + 1] = {
      process = process,
      title = if #entry.names > 0
        then table.concat(entry.names, ', ')
        else entry.label or 'Process ' .. tostring(process.id),
      detail = '#' .. tostring(process.id),
      trailing = rowState(entry.state, choice.audioAvailable),
    }
  end
  return rows
end

settingsOf = function(choice: selection.State, renderer: Renderer): Settings
  local attended = choice.attended
  local notice = if not choice.attentionAvailable
    then 'Attention unavailable: frame, panels, or surfaces provider is missing'
    elseif choice.mode == 'attention' then 'Attention pauses while this panel is open'
    else nil
  return table.freeze {
    enabled = renderer.enabled(),
    reactive = choice.reactive,
    mode = choice.mode,
    response = choice.response,
    motion = choice.motion,
    diagnostic = choice.diagnostic,
    pinReason = if choice.mode ~= 'attention'
      then 'Pinning is available with the Attention source.'
      elseif attended == nil or attended.dead then 'No application is attended.'
      else nil,
    status = choice:status(),
    notice = notice,
  }
end

sameSettings = function(left: Settings, right: Settings): boolean
  return left.enabled == right.enabled
    and left.reactive == right.reactive
    and left.mode == right.mode
    and left.response == right.response
    and left.motion == right.motion
    and left.diagnostic == right.diagnostic
    and left.pinReason == right.pinReason
    and left.status == right.status
    and left.notice == right.notice
end

sameApplications = function(left: { Application }, right: { Application }): boolean
  if #left ~= #right then
    return false
  end
  for index, entry in left do
    local other = right[index]
    if
      entry.token ~= other.token
      or entry.title ~= other.title
      or entry.detail ~= other.detail
      or entry.trailing ~= other.trailing
      or entry.selected ~= other.selected
    then
      return false
    end
  end
  return true
end

rowState = function(state: audio.State?, audioAvailable: boolean): string
  if state then
    if state.kind == 'active' then
      return if state.provenance == 'application-metadata' then 'active (application metadata)' else 'active'
    elseif state.kind == 'idle' then
      return 'silent'
    elseif state.kind == 'unavailable' then
      return 'unavailable (' .. state.reason .. ')'
    else
      return state.kind
    end
  end
  return if audioAvailable then 'no audio stream' else 'audio provider unavailable'
end

return stores

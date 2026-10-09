-- Arrangement data and window slots persist across provider activations. Each binding's source and listeners end with its activation.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local panelsContract = require '@lunette-contracts/panels'
local rulesContract = require '@lunette-contracts/rules'
local tagsContract = require '@lunette-contracts/tags'
local vocabulary = require '@lunette-contracts/vocabulary'
local format = require '@lunette-plugins/arrangement/format'
local logging = require '@lunette-plugins/desktop/logging'
local slots = require '@lunette-plugins/arrangement/slots'
local capture = require '@lunette-plugins/arrangement/capture'

local state = {}

export type Entry = format.Entry
export type File = format.File
export type Loaded = format.Loaded
export type Filesystem = {
  read: (string) -> string?,
  write: (string, string) -> boolean,
  getSaveDirectory: () -> string,
}
export type Dependencies = {
  read filesystem: Filesystem?,
  read report: ((string) -> ())?,
  read file: string?,
}
export type Slots = slots.Slots
export type Identified = slots.Identified
export type Binding = {
  read active: (Binding) -> boolean,
  read save: (Binding) -> (boolean, string?),
  -- Places the live panels where the arrangement last loaded or saved has
  -- them, and answers how many it placed.
  read restore: (Binding) -> number,
}
export type State = {
  read loaded: (State) -> format.Loaded,
  read arrangement: (State) -> format.File,
  read declined: (State) -> string?,
  read capture: (State, panelsContract.Service, tagsContract.Service) -> format.File,
  read bind: (
    State,
    plugin.Context,
    panelsContract.Service,
    tagsContract.Service,
    rulesContract.Service
  ) -> Binding,
}

type Scope = {
  context: plugin.Context,
  panels: panelsContract.Service,
  tags: tagsContract.Service,
}

local SOURCE = 'desktop.persist'
local PRECEDENCE = vocabulary.PRECEDENCE.persisted
local FILE = 'arrangement.state'

state.FILE = FILE
state.PRECEDENCE = PRECEDENCE
state.SOURCE = SOURCE

local function defaultFilesystem(): Filesystem
  return {
    read = function(filename: string): string?
      local text: string? = lovr.filesystem.read(filename)
      return text
    end,
    write = function(filename: string, text: string): boolean
      local written: boolean = lovr.filesystem.write(filename, text)
      return written
    end,
    getSaveDirectory = function(): string
      return lovr.filesystem.getSaveDirectory()
    end,
  }
end

local function defaultReport(message: string): ()
  logging.report(message, 'warn')
end

function state.path(filesystem: Filesystem?, file: string?): string
  local selected = filesystem or defaultFilesystem()
  return selected.getSaveDirectory() .. '/' .. (file or FILE)
end

-- Resolves held slots without assigning one until placement holds it.
function state.source(file: format.File, held: slots.Slots?): (lunette.Window) -> rulesContract.Properties?
  local available = capture.slotsFor(file)
  local holding = held or slots.new()
  return function(window: lunette.Window): rulesContract.Properties?
    return capture.answer(available, holding, window)
  end
end

state.slots = slots.new

function state.new(dependencies: Dependencies?): State
  local given: Dependencies = dependencies or {}
  local filesystem = given.filesystem or defaultFilesystem()
  local report = given.report or defaultReport
  local file = given.file or FILE
  if type(file) ~= 'string' or file == '' then
    error('desktop.persist: file is a non-empty file name, not ' .. tostring(file), 2)
  end
  local text = filesystem.read(file)
  local loaded: format.Loaded = if text then format.read(text) else format.empty()

  local arrangement: format.File = format.newFile {}
  local declined: string? = nil
  -- Held slots prevent live windows from changing identity slots during provider outages.
  local held = slots.new()
  if loaded.kind == 'arrangement' then
    arrangement = loaded.file
  elseif loaded.kind == 'broken' then
    declined = state.path(filesystem, file) .. ' could not be read: ' .. loaded.message .. ', so it is left alone'
    report(declined)
  elseif loaded.kind == 'fromTheFuture' then
    declined = state.path(filesystem, file)
      .. ' was written by version '
      .. loaded.found
      .. ', and this lunette writes version '
      .. loaded.supported
      .. ', so it is left alone'
    report(declined)
  end
  for _, message in ipairs(loaded.skipped) do
    report(message)
  end

  -- Each unmatched entry is reported once per loaded or saved arrangement.
  local reportedStale: { [Entry]: boolean } = setmetatable({} :: { [Entry]: boolean }, { __mode = 'k' })
  local function restore(context: plugin.Context, panels: panelsContract.Service, tags: tagsContract.Service): number
    local restored, stale = capture.restore(report, held, context, panels, tags, arrangement)
    for _, entry in ipairs(stale) do
      if not reportedStale[entry] then
        reportedStale[entry] = true
        report('nothing matched the saved ' .. entry.kind .. " '" .. entry.key .. "'")
      end
    end
    return #restored
  end

  local state: State = {
    loaded = function(_self: State): format.Loaded
      return loaded
    end,
    arrangement = function(_self: State): format.File
      return arrangement
    end,
    declined = function(_self: State): string?
      return declined
    end,
    capture = function(_self: State, panels: panelsContract.Service, tags: tagsContract.Service): format.File
      return capture.capture(report, held, panels, tags)
    end,
    bind = function(
      _self: State,
      context: plugin.Context,
      panels: panelsContract.Service,
      tags: tagsContract.Service,
      rules: rulesContract.Service
    ): Binding
      if not context:active() then
        error 'desktop.persist: the provider scope is no longer active'
      end

      -- Clear service references when the activation ends.
      local scope: Scope? = { context = context, panels = panels, tags = tags }
      context:effect(function(): () -> ()
        return function(): ()
          scope = nil
        end
      end)
      local function live(): Scope?
        local current = scope
        if current and current.context:active() then
          return current
        end
        return nil
      end
      -- Resolve against the current arrangement when saved windows arrive later.
      local cachedFile: format.File? = nil
      local cachedSlots: { [string]: Entry } = {}
      local function available(): { [string]: Entry }
        if cachedFile ~= arrangement then
          cachedFile = arrangement
          cachedSlots = capture.slotsFor(arrangement)
        end
        return cachedSlots
      end
      local function save(): (boolean, string?)
        local current = live()
        if not current then
          return false, 'desktop.persist: the provider binding is no longer active'
        end
        if declined then
          return false, declined
        end
        local captured = capture.capture(report, held, current.panels, current.tags)
        -- Reporting can end the activation during capture.
        if not live() then
          return false, 'desktop.persist: the provider binding is no longer active'
        end
        if not filesystem.write(file, format.render(captured)) then
          return false, state.path(filesystem, file) .. ' could not be written'
        end
        arrangement = captured
        declined = nil
        return true, nil
      end
      local public: Binding = {
        active = function(_binding: Binding): boolean
          return live() ~= nil
        end,
        save = function(_binding: Binding): (boolean, string?)
          return save()
        end,
        restore = function(_binding: Binding): number
          local current = live()
          if not current then
            return 0
          end
          return restore(current.context, current.panels, current.tags)
        end,
      }
      rules:addSource(context, {
        name = SOURCE,
        precedence = PRECEDENCE,
        resolve = function(window: lunette.Window): rulesContract.Properties?
          if not live() then
            return nil
          end
          return capture.answer(available(), held, window)
        end,
      })
      restore(context, panels, tags)
      panels:onAdded(context, function(target: panelsContract.Panel)
        local current = live()
        if current then
          capture.arrived(report, held, current.context, current.panels, current.tags, arrangement, target)
        end
      end)
      return public
    end,
  }
  return state
end

return state

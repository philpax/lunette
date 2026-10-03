-- Persistent arrangement state that outlives provider activations; each binding belongs to one activation,
-- and its source and listener are effects of that activation's context. A binding saves when asked, the desktop asking on a drop and at quit. A window holds
-- its saved slot from its panel's creation until it dies.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local panelsContract = require '@lunette-contracts/panels'
local rulesContract = require '@lunette-contracts/rules'
local tagsContract = require '@lunette-contracts/tags'
local vocabulary = require '@lunette-contracts/vocabulary'
local format = require '@lunette-plugins/arrangement/format'
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
-- How an arrangement is written as text and read back. A reader answers fromTheFuture for a version it
-- cannot represent, so a file it could not write back whole is left alone.
export type Format = {
  read read: (unknown) -> format.Loaded,
  read render: (format.File) -> string,
}
-- What a persistence state is made from: the save-directory `file`, its `format`, and `keyFor`, the
-- identity a window or monitor is saved under.
export type Dependencies = {
  read filesystem: Filesystem?,
  read report: ((string) -> ())?,
  read file: string?,
  read format: Format?,
  read keyFor: slots.KeyFor?,
}
export type Slots = slots.Slots
export type KeyFor = slots.KeyFor
export type Identified = slots.Identified
export type SaveOptions = { read force: boolean? }
export type Binding = {
  read active: (Binding) -> boolean,
  read save: (Binding, SaveOptions?) -> (boolean, string?),
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

-- What a binding reaches while its activation lasts.
type Scope = {
  context: plugin.Context,
  panels: panelsContract.Service,
  tags: tagsContract.Service,
}

local SOURCE = 'desktop.persist'
local PRECEDENCE = vocabulary.PRECEDENCE.persisted
local FILE = 'arrangement.state'

state.FORMAT = table.freeze { read = format.read, render = format.render } :: Format
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
  local log = lovr.log
  if log then
    log(message, 'warn', 'desktop.persist')
  end
end

function state.path(filesystem: Filesystem?, file: string?): string
  local selected = filesystem or defaultFilesystem()
  return selected.getSaveDirectory() .. '/' .. (file or FILE)
end

-- A rules source over one file. Resolving is pure: a window answers the slot it holds, or the lowest free
-- one, and takes a slot only when held.
function state.source(file: format.File, held: slots.Slots?): (lunette.Window) -> rulesContract.Properties?
  local available = capture.slotsFor(file)
  local holding = held or slots.new()
  return function(window: lunette.Window): rulesContract.Properties?
    return capture.answer(available, holding, window)
  end
end

state.slots = slots.new

-- Reads the file through the format. A reader that raises or answers a non-load makes a broken load, so the
-- file is left alone.
local function load(chosen: Format, text: string): format.Loaded
  local ok, answered = pcall(chosen.read, text)
  if not ok then
    return format.broken('the format could not read it: ' .. tostring(answered))
  end
  if not format.isLoaded(answered) then
    return format.broken('the format answered a ' .. type(answered) .. ', not a load')
  end
  return answered
end

function state.new(dependencies: Dependencies?): State
  local given: Dependencies = dependencies or {}
  local filesystem = given.filesystem or defaultFilesystem()
  local report = given.report or defaultReport
  local file = given.file or FILE
  if type(file) ~= 'string' or file == '' then
    error('desktop.persist: file is a non-empty file name, not ' .. tostring(file), 2)
  end
  local chosen: Format = given.format or state.FORMAT
  if type(chosen) ~= 'table' or type(chosen.read) ~= 'function' or type(chosen.render) ~= 'function' then
    error('desktop.persist: format is a table of read and render functions', 2)
  end
  if given.keyFor ~= nil and type(given.keyFor) ~= 'function' then
    error('desktop.persist: keyFor is a function, not a ' .. type(given.keyFor), 2)
  end
  local loaded: format.Loaded
  local text = filesystem.read(file)
  if text then
    loaded = load(chosen, text)
  else
    loaded = format.empty()
  end

  local arrangement: format.File = format.newFile {}
  local declined: string? = nil
  -- Held across bindings, so a provider outage does not move a live window to
  -- another window's slot.
  local held = slots.new(given.keyFor)
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

  -- An unmatched saved entry is reported once per file loaded or saved. Weak keys, so a replaced
  -- arrangement's entries are not retained.
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

      -- Dropped when the activation ends, so a binding kept past it retains no retired service.
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
      -- Read when they run, so a save through this binding reaches windows that appear after it.
      local cachedFile: format.File? = nil
      local cachedSlots: { [string]: Entry } = {}
      local function available(): { [string]: Entry }
        if cachedFile ~= arrangement then
          cachedFile = arrangement
          cachedSlots = capture.slotsFor(arrangement)
        end
        return cachedSlots
      end
      local function save(options: SaveOptions?): (boolean, string?)
        local current = live()
        if not current then
          return false, 'desktop.persist: the provider binding is no longer active'
        end
        if declined and not (options and options.force) then
          return false, declined
        end
        local captured = capture.capture(report, held, current.panels, current.tags)
        -- Capture reports, and a report can end the activation.
        if not live() then
          return false, 'desktop.persist: the provider binding is no longer active'
        end
        local rendered = chosen.render(captured)
        if type(rendered) ~= 'string' then
          return false, 'desktop.persist: the format rendered a ' .. type(rendered) .. ', not text'
        end
        if not filesystem.write(file, rendered) then
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
        save = function(_binding: Binding, options: SaveOptions?): (boolean, string?)
          return save(options)
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

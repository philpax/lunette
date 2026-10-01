-- Persistent arrangement state that outlives provider activations; each binding owns only its activation's
-- source and listeners. A binding saves when asked, the desktop asking on a drop and at quit. A window holds
-- its saved slot from its panel's creation until it dies.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local panelsContract = require '@lunette-contracts/panels'
local rulesContract = require '@lunette-contracts/rules'
local tagsContract = require '@lunette-contracts/tags'
local vocabulary = require '@lunette-contracts/vocabulary'
local format = require '@lunette-desktop/persist/format'
local slots = require '@lunette-desktop/persist/slots'
local arrangements = require '@lunette-desktop/persist/arrangement'

local persist = {}

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
  read dispose: (Binding) -> (),
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

type BindingState = {
  active: boolean,
  context: plugin.Context?,
  panels: panelsContract.Service?,
  tags: tagsContract.Service?,
  sourceEffect: plugin.Effect?,
  addedEffect: plugin.Effect?,
  ownerEffect: plugin.Effect?,
}

local SOURCE = 'desktop.persist'
local PRECEDENCE = vocabulary.PRECEDENCE.persisted
local FILE = 'arrangement.state'

persist.CURRENT_VERSION = format.CURRENT_VERSION
persist.newFile = format.newFile
persist.isFile = format.isFile
persist.isLoaded = format.isLoaded
persist.entries = format.entries
persist.read = format.read
persist.render = format.render
persist.empty = format.empty
persist.arrangement = format.arrangement
persist.fromTheFuture = format.fromTheFuture
persist.broken = format.broken
persist.defaultKey = slots.defaultKey
persist.FORMAT = table.freeze { read = format.read, render = format.render } :: Format
persist.FILE = FILE
persist.PRECEDENCE = PRECEDENCE
persist.SOURCE = SOURCE

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

function persist.path(filesystem: Filesystem?, file: string?): string
  local selected = filesystem or defaultFilesystem()
  return selected.getSaveDirectory() .. '/' .. (file or FILE)
end

-- A rules source over one file. Resolving is pure: a window answers the slot it holds, or the lowest free
-- one, and takes a slot only when held.
function persist.source(file: format.File, held: slots.Slots?): (lunette.Window) -> rulesContract.Properties?
  local available = arrangements.slotsFor(file)
  local holding = held or slots.new()
  return function(window: lunette.Window): rulesContract.Properties?
    return arrangements.answer(available, holding, window)
  end
end

persist.slots = slots.new

local function bindingLive(binding: BindingState): boolean
  local context = binding.context
  return binding.active and context ~= nil and context:active()
end

local function disposeEffect(effect: plugin.Effect?): string?
  if not effect then
    return nil
  end
  local ok, failure = pcall(function()
    effect:dispose()
  end)
  if not ok then
    return tostring(failure)
  end
  return nil
end

local function deactivate(binding: BindingState): ()
  if not binding.active then
    return
  end
  binding.active = false
  local addedFailure = disposeEffect(binding.addedEffect)
  binding.addedEffect = nil
  local sourceFailure = disposeEffect(binding.sourceEffect)
  binding.sourceEffect = nil
  binding.context = nil
  binding.panels = nil
  binding.tags = nil
  binding.ownerEffect = nil
  if addedFailure then
    error(addedFailure)
  end
  if sourceFailure then
    error(sourceFailure)
  end
end

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

function persist.new(dependencies: Dependencies?): State
  local given: Dependencies = dependencies or {}
  local filesystem = given.filesystem or defaultFilesystem()
  local report = given.report or defaultReport
  local file = given.file or FILE
  if type(file) ~= 'string' or file == '' then
    error('desktop.persist: file is a non-empty file name, not ' .. tostring(file), 2)
  end
  local chosen: Format = given.format or persist.FORMAT
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
    declined = persist.path(filesystem, file) .. ' could not be read: ' .. loaded.message .. ', so it is left alone'
    report(declined)
  elseif loaded.kind == 'fromTheFuture' then
    declined = persist.path(filesystem, file)
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
    local restored, stale = arrangements.restore(report, held, context, panels, tags, arrangement)
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
      return arrangements.capture(report, held, panels, tags)
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

      local binding: BindingState = {
        active = true,
        context = context,
        panels = panels,
        tags = tags,
        sourceEffect = nil,
        addedEffect = nil,
        ownerEffect = nil,
      }
      -- Read when they run, so a save through this binding reaches windows that appear after it.
      local cachedFile: format.File? = nil
      local cachedSlots: { [string]: Entry } = {}
      local function available(): { [string]: Entry }
        if cachedFile ~= arrangement then
          cachedFile = arrangement
          cachedSlots = arrangements.slotsFor(arrangement)
        end
        return cachedSlots
      end
      local function save(options: SaveOptions?): (boolean, string?)
        if not bindingLive(binding) then
          return false, 'desktop.persist: the provider binding is no longer active'
        end
        if declined and not (options and options.force) then
          return false, declined
        end
        local currentPanels = binding.panels
        local currentTags = binding.tags
        if not currentPanels or not currentTags then
          return false, 'desktop.persist: the provider binding is no longer active'
        end
        local captured = arrangements.capture(report, held, currentPanels, currentTags)
        if not bindingLive(binding) then
          return false, 'desktop.persist: the provider binding is no longer active'
        end
        local rendered = chosen.render(captured)
        if type(rendered) ~= 'string' then
          return false, 'desktop.persist: the format rendered a ' .. type(rendered) .. ', not text'
        end
        if not filesystem.write(file, rendered) then
          return false, persist.path(filesystem, file) .. ' could not be written'
        end
        arrangement = captured
        declined = nil
        return true, nil
      end
      local public: Binding = {
        active = function(_binding: Binding): boolean
          return bindingLive(binding)
        end,
        save = function(_binding: Binding, options: SaveOptions?): (boolean, string?)
          return save(options)
        end,
        restore = function(_binding: Binding): number
          local currentContext, currentPanels, currentTags = binding.context, binding.panels, binding.tags
          if not bindingLive(binding) or not currentContext or not currentPanels or not currentTags then
            return 0
          end
          return restore(currentContext, currentPanels, currentTags)
        end,
        dispose = function(_binding: Binding): ()
          local effect = binding.ownerEffect
          if effect then
            effect:dispose()
          end
        end,
      }
      local ok, failure = pcall(function(): ()
        local source = function(window: lunette.Window): rulesContract.Properties?
          if not bindingLive(binding) then
            return nil
          end
          return arrangements.answer(available(), held, window)
        end
        binding.sourceEffect = rules:addSource(context, { name = SOURCE, precedence = PRECEDENCE, resolve = source })
        restore(context, panels, tags)
        binding.addedEffect = panels:onAdded(context, function(target: panelsContract.Panel)
          if bindingLive(binding) then
            arrangements.arrived(report, held, context, panels, tags, arrangement, target)
          end
        end)
        binding.ownerEffect = context:effect(function(): () -> ()
          return function(): ()
            deactivate(binding)
          end
        end)
      end)
      if not ok then
        binding.active = false
        disposeEffect(binding.addedEffect)
        disposeEffect(binding.sourceEffect)
        binding.context = nil
        binding.panels = nil
        binding.tags = nil
        error(failure)
      end
      return public
    end,
  }
  return state
end

return persist

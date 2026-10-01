-- Persistent arrangement state outlives provider activations, while each provider
-- binding owns only the source and listeners registered for that activation.
--
-- A binding saves when a grab drops a panel; the configuration saves again at
-- quit. Its rules source and its arrival listener read the arrangement last
-- loaded or saved. A window holds its saved slot from its panel's creation
-- until the window dies, and a monitor panel that appears after the binding is
-- restored as it appears.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local panelsContract = require '@lunette-contracts/panels'
local rulesContract = require '@lunette-contracts/rules'
local tagsContract = require '@lunette-contracts/tags'
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
export type Dependencies = {
  read filesystem: Filesystem?,
  read report: ((string) -> ())?,
}
export type Slots = slots.Slots
export type SaveOptions = { read force: boolean? }
export type Binding = {
  read active: (Binding) -> boolean,
  read save: (Binding, SaveOptions?) -> (boolean, string?),
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
  droppedEffect: plugin.Effect?,
  addedEffect: plugin.Effect?,
  ownerEffect: plugin.Effect?,
}

local SOURCE = 'desktop.persist'
local PRECEDENCE = 200
local FILE = 'arrangement.state'

persist.CURRENT_VERSION = format.CURRENT_VERSION
persist.newFile = format.newFile
persist.isFile = format.isFile
persist.isLoaded = format.isLoaded
persist.entries = format.entries
persist.read = format.read
persist.render = format.render
persist.empty = format.empty
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

function persist.path(filesystem: Filesystem?): string
  local selected = filesystem or defaultFilesystem()
  return selected.getSaveDirectory() .. '/' .. FILE
end

-- A rules source over one file. Resolving is a pure query: a window answers
-- the slot it holds in held, or the lowest slot no live window holds, and
-- resolving never takes a slot. A window takes its slot when it is held. With
-- no slots given, no window holds one.
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
  local droppedFailure = disposeEffect(binding.droppedEffect)
  binding.droppedEffect = nil
  local sourceFailure = disposeEffect(binding.sourceEffect)
  binding.sourceEffect = nil
  binding.context = nil
  binding.panels = nil
  binding.tags = nil
  binding.ownerEffect = nil
  if addedFailure then
    error(addedFailure)
  end
  if droppedFailure then
    error(droppedFailure)
  end
  if sourceFailure then
    error(sourceFailure)
  end
end

function persist.new(dependencies: Dependencies?): State
  local filesystem = if dependencies then dependencies.filesystem or defaultFilesystem() else defaultFilesystem()
  local report = if dependencies then dependencies.report or defaultReport else defaultReport
  local loaded: format.Loaded
  local text = filesystem.read(FILE)
  if text then
    loaded = format.read(text)
  else
    loaded = format.empty()
  end

  local arrangement: format.File = format.newFile {}
  local declined: string? = nil
  -- Held across bindings, so a provider outage does not move a live window to
  -- another window's slot.
  local held = slots.new()
  if loaded.kind == 'arrangement' then
    arrangement = loaded.file
  elseif loaded.kind == 'broken' then
    declined = persist.path(filesystem) .. ' could not be read: ' .. loaded.message .. ', so it is left alone'
    report(declined)
  elseif loaded.kind == 'fromTheFuture' then
    declined = persist.path(filesystem)
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
        droppedEffect = nil,
        addedEffect = nil,
        ownerEffect = nil,
      }
      -- The source and the arrival listener read the arrangement when they
      -- run, so a save made through this binding reaches the windows and
      -- monitors that appear after it.
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
        local file = arrangements.capture(report, held, currentPanels, currentTags)
        if not bindingLive(binding) then
          return false, 'desktop.persist: the provider binding is no longer active'
        end
        if not filesystem.write(FILE, format.render(file)) then
          return false, persist.path(filesystem) .. ' could not be written'
        end
        arrangement = file
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
        binding.droppedEffect = panels:onDropped(context, {
          run = function()
            if bindingLive(binding) then
              local written, message = save(nil)
              if not written and message then
                report(message)
              end
            end
          end,
        })
        arrangements.restore(report, held, context, panels, tags, arrangement)
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
        disposeEffect(binding.droppedEffect)
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

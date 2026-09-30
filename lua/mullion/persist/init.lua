-- Persistent arrangement state outlives provider activations, while each provider
-- binding owns only the source and callback registered for that activation.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local panelsContract = require '@lunette-contracts/panels'
local rulesContract = require '@lunette-contracts/rules'
local tagsContract = require '@lunette-contracts/tags'
local format = require '@mullion/persist/format'
local pose = require '@mullion/pose'

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
  ownerEffect: plugin.Effect?,
}

local SOURCE = 'mullion.persist'
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
    log(message, 'warn', 'mullion.persist')
  end
end

function persist.path(filesystem: Filesystem?): string
  local selected = filesystem or defaultFilesystem()
  return selected.getSaveDirectory() .. '/' .. FILE
end

local function sourceKey(target: panelsContract.Panel): string?
  local key: string?
  if target.kind == 'window' then
    local source = target.source
    if source.dead then
      return nil
    end
    key = source.appId
  else
    local source = target.source
    if source.dead then
      return nil
    end
    local monitorId = source.id
    if type(monitorId) == 'string' then
      key = monitorId
    end
  end
  if type(key) ~= 'string' or key == '' then
    return nil
  end
  return key
end

local function slotKey(kind: string, key: string, slot: number): string
  return kind .. '\0' .. key .. '\0' .. slot
end

local function slotsFor(file: format.File): { [string]: Entry }
  local available: { [string]: Entry } = {}
  for _, entry in ipairs(format.entries(file)) do
    available[slotKey(entry.kind, entry.key, entry.slot)] = entry
  end
  return available
end

function persist.source(file: format.File): (lunette.Window) -> rulesContract.Properties?
  local available = slotsFor(file)
  local assigned: { [number]: Entry } = {}
  local counts: { [string]: number } = {}

  return function(window: lunette.Window): rulesContract.Properties?
    local appId = window.appId
    if type(appId) ~= 'string' or appId == '' then
      return nil
    end

    local identity = window.id
    local existing = assigned[identity]
    if existing then
      return { pose = existing.pose, width = existing.width, height = existing.height, tags = existing.tags }
    end

    local slot = (counts[appId] or 0) + 1
    counts[appId] = slot
    local entry = available[slotKey('window', appId, slot)]
    if not entry then
      return nil
    end
    assigned[identity] = entry
    return { pose = entry.pose, width = entry.width, height = entry.height, tags = entry.tags }
  end
end

local function capture(report: (string) -> (), panels: panelsContract.Service, tags: tagsContract.Service): format.File
  local entries: { Entry } = {}
  local counts: { [string]: number } = {}
  for _, target in ipairs(panels:all()) do
    if not target.dead then
      local key = sourceKey(target)
      if key then
        local counted = target.kind .. '\0' .. key
        local slot = (counts[counted] or 0) + 1
        counts[counted] = slot
        local names: { string } = {}
        for _, existing in ipairs(tags:all()) do
          if existing:has(target) then
            names[#names + 1] = existing.name
          end
        end
        entries[#entries + 1] = {
          kind = target.kind,
          key = key,
          slot = slot,
          pose = pose.encode(target.pose),
          width = target.width,
          height = target.height,
          tags = names,
        }
      else
        report('a ' .. target.kind .. ' panel has no identity, so it is not saved')
      end
    end
  end
  return format.newFile(entries)
end

local function restore(
  report: (string) -> (),
  context: plugin.Context,
  panels: panelsContract.Service,
  tags: tagsContract.Service,
  file: format.File
): ({ panelsContract.Panel }, { Entry })
  local available = slotsFor(file)
  local restored: { panelsContract.Panel } = {}
  local matched: { [Entry]: boolean } = {}
  local counts: { [string]: number } = {}

  for _, target in ipairs(panels:all()) do
    if not target.dead then
      local key = sourceKey(target)
      if key then
        local counted = target.kind .. '\0' .. key
        local slot = (counts[counted] or 0) + 1
        counts[counted] = slot
        local entry = available[slotKey(target.kind, key, slot)]
        if entry then
          local placed = pose.decode(entry.pose)
          if placed then
            target:setPose(placed)
            if entry.width or entry.height then
              target:setSize(entry.width, entry.height)
            end
            for _, name in ipairs(entry.tags) do
              local found = tags:find(name)
              if found then
                found:add(target)
              else
                local created = tags:new(context, name)
                created:add(target)
              end
            end
            restored[#restored + 1] = target
            matched[entry] = true
          else
            report("the pose saved for '" .. entry.key .. "' is not sixteen numbers")
          end
        end
      end
    end
  end

  local stale: { Entry } = {}
  for _, entry in ipairs(format.entries(file)) do
    if not matched[entry] then
      stale[#stale + 1] = entry
      report('nothing matched the saved ' .. entry.kind .. " '" .. entry.key .. "'")
    end
  end
  return restored, stale
end

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
  local droppedFailure = disposeEffect(binding.droppedEffect)
  binding.droppedEffect = nil
  local sourceFailure = disposeEffect(binding.sourceEffect)
  binding.sourceEffect = nil
  binding.context = nil
  binding.panels = nil
  binding.tags = nil
  binding.ownerEffect = nil
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
  if loaded.kind == 'arrangement' then
    arrangement = loaded.file
  elseif loaded.kind == 'broken' then
    declined = persist.path(filesystem) .. ' could not be read: ' .. loaded.message .. ', so it is left alone'
    report(declined)
  elseif loaded.kind == 'fromTheFuture' then
    declined = persist.path(filesystem)
      .. ' was written by version '
      .. loaded.found
      .. ', and this mullion writes version '
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
      return capture(report, panels, tags)
    end,
    bind = function(
      _self: State,
      context: plugin.Context,
      panels: panelsContract.Service,
      tags: tagsContract.Service,
      rules: rulesContract.Service
    ): Binding
      if not context:active() then
        error 'mullion.persist: the provider scope is no longer active'
      end

      local binding: BindingState = {
        active = true,
        context = context,
        panels = panels,
        tags = tags,
        sourceEffect = nil,
        droppedEffect = nil,
        ownerEffect = nil,
      }
      local resolve = persist.source(arrangement)
      local function save(options: SaveOptions?): (boolean, string?)
        if not bindingLive(binding) then
          return false, 'mullion.persist: the provider binding is no longer active'
        end
        if declined and not (options and options.force) then
          return false, declined
        end
        local currentPanels = binding.panels
        local currentTags = binding.tags
        if not currentPanels or not currentTags then
          return false, 'mullion.persist: the provider binding is no longer active'
        end
        local file = capture(report, currentPanels, currentTags)
        if not bindingLive(binding) then
          return false, 'mullion.persist: the provider binding is no longer active'
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
          return resolve(window)
        end
        binding.sourceEffect = rules:addSource(context, SOURCE, PRECEDENCE, source)
        binding.droppedEffect = panels:onDropped(context, nil, function()
          if bindingLive(binding) then
            local written, message = save(nil)
            if not written and message then
              report(message)
            end
          end
        end)
        restore(report, context, panels, tags, arrangement)
        binding.ownerEffect = context:effect(function(): () -> ()
          return function(): ()
            deactivate(binding)
          end
        end)
      end)
      if not ok then
        binding.active = false
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

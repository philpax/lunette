-- Arrangements that survive a hard restart. The native property store covers a
-- soft reload, while this file survives with the compositor gone. Entries use a
-- window's `appId` and slot, or a monitor's saved identity, rather than
-- compositor-local window IDs.
-- A mirrored monitor has no native per-source property-store API, so its pose
-- persists here until that native API can represent it.
-- Restore is a `mullion.rules` source, so configuration controls its precedence.
-- `mullion.persist.format` owns the text format; this module owns filesystem I/O,
-- reporting, and conversion to panels. The file lives in the identity's save
-- directory, not beside the configuration.

local lunette = require '@lunette'

local format = require '@mullion/persist/format'
local pointing = require '@mullion/interaction/types'
local panel = require '@mullion/panel'
local pose = require '@mullion/pose'
local rules = require '@mullion/rules'
local tag = require '@mullion/tag'
local teardown = require '@mullion/teardown'

local persist = {}

-- One entry as an arrangement holds it, matching `mullion.persist.format`.
type Entry = format.Entry

-- What an arrangement is captured from and restored onto.
--
-- A `mullion.panel` panel is one, and so is an object of a configuration's own
-- carrying the same fields, which is why this is a shape rather than that type.
-- `source` is what the entry's key is read from: a window's `appId` or a
-- monitor's `id`, per `sourceKey`.
-- A surface an arrangement is captured from and restored onto: one that is over
-- something, and whose size in metres is known.
--
-- `mullion.interaction`'s contract and the little this adds, rather than a shape
-- of its own. Intersecting it narrows `kind` to the two backed forms, so a
-- surface over nothing — a keyboard, a button a configuration drew — is not one
-- an arrangement can name, which is true: there is nothing to key it on. It also
-- narrows `pose`, `width`, and `height` from the contract's optionals, because a
-- panel always has all three.
export type Placed = pointing.Surface & {
  read kind: panel.Kind,
  read pose: Mat4,
  read width: number,
  read height: number,
}

-- What this module answers `mullion.rules` with. Its own name for that module's
-- evaluated form, because an arrangement holds values rather than rules.
type Properties = rules.Resolved
type Filesystem = {
  read: (string) -> string?,
  write: (string, string) -> boolean,
  getSaveDirectory: () -> string,
}

local sourceKey, slotsFor, slotKey

local function defaultFilesystem(): Filesystem
  return {
    read = function(filename: string): string?
      local text = lovr.filesystem.read(filename)
      return text
    end,
    write = function(filename: string, text: string): boolean
      local ok = lovr.filesystem.write(filename, text)
      return ok
    end,
    getSaveDirectory = function(): string
      return lovr.filesystem.getSaveDirectory()
    end,
  }
end

-- Why the last load could not be used, or nothing. A newer format or unreadable
-- file arms this refusal so a later save built from live panels cannot overwrite
-- data this version cannot represent, preventing old-writer-with-new-data corruption.
-- A usable load clears it.
local declined: string? = nil

-- The format's surface, so that a configuration requires one module. The
-- versions and the text are documented in `mullion.persist.format`.
persist.CURRENT_VERSION = format.CURRENT_VERSION
persist.newFile = format.newFile
persist.isFile = format.isFile
persist.isLoaded = format.isLoaded
persist.entries = format.entries
persist.read = format.read
persist.render = format.render

-- Where the arrangement is kept, under the save directory.
--
-- No `.lua` extension deliberately. `etc/xdg/lunette/conf.lua` sets
-- `t.saveprecedence = false` so that the save directory is mounted behind the
-- standard library rather than ahead of it, and a file that could never be
-- resolved as a module in the first place does not depend on that staying true.
persist.FILE = 'arrangement.state'

-- Where `install` registers the restore source.
--
-- Above `mullion.rules.DEFAULT_PRECEDENCE`, so a saved pose beats the rule that
-- would otherwise have placed the window. A configuration that wants the rules
-- to win passes a lower number; that is the statement the sources exist to make.
persist.PRECEDENCE = 200

-- The name `install` registers under.
persist.SOURCE = 'mullion.persist'

-- Where a stale or unreadable entry is reported.
--
-- Replaceable for host diagnostics and specs. Reports are warnings because a
-- stale entry is lost state, not a reason to stop the session.
function persist.report(message)
  local log = lovr.log
  if log then
    log(message, 'warn', 'mullion.persist')
  end
end

-- The arrangement in `value`, which is an arrangement, a load, or nothing.
--
-- Unwraps a load once, so callers can use `persist.install(persist.load())`.
-- A broken or future file yields an empty arrangement rather than being restored.
function persist.arrangementOf(value: format.File | format.Loaded | nil): format.File
  if value == nil then
    return format.newFile {}
  end
  if format.isFile(value) then
    return value :: format.File
  end
  if format.isLoaded(value) then
    local loaded: format.Loaded = value :: format.Loaded
    local forSession = loaded.forSession
    if forSession then
      return forSession(loaded) or format.newFile {}
    end
    return format.newFile {}
  end
  error('mullion.persist: an arrangement is one this module made, not a ' .. type(value), 2)
end

-- The arrangement `panels` are in.
--
-- A panel whose source carries no identity is reported and left out. Writing it
-- under an empty key would restore it onto the first source that also had none.
function persist.capture(panels: { read [number]: Placed }): format.File
  local entries: { Entry } = {}
  local counts: { [string]: number } = {}
  for index = 1, #panels do
    local target = panels[index]
    if not target.dead then
      local key = sourceKey(target)
      if key then
        local counted = target.kind .. '\0' .. key
        local slot = (counts[counted] or 0) + 1
        counts[counted] = slot
        entries[#entries + 1] = {
          kind = target.kind,
          key = key,
          slot = slot,
          pose = pose.encode(target.pose),
          width = target.width,
          height = target.height,
          tags = persist.tagsOf(target),
        }
      else
        persist.report('a ' .. tostring(target.kind) .. ' panel has no identity, so it is not saved')
      end
    end
  end
  return format.newFile(entries)
end

-- The names of the tags `target` is on, in `mullion.tag.all` order.
function persist.tagsOf(target: tag.Panel): { string }
  local names: { string } = {}
  for _, existing in ipairs(tag.all()) do
    if existing:has(target) then
      names[#names + 1] = existing.name
    end
  end
  return names
end

-- The properties an entry describes, as `mullion.rules` takes them.
--
-- The pose stays the string `mullion.pose` wrote. `mullion.rules` decodes one,
-- and handing it through unchanged keeps one encoding rather than two.
function persist.properties(entry: Entry): Properties
  return {
    pose = entry.pose,
    width = entry.width,
    height = entry.height,
    tags = entry.tags,
  }
end

-- Puts `target` back where `entry` says it was, reporting whether it went.
function persist.apply(entry: Entry, target: Placed): boolean
  if target.dead then
    return false
  end

  local placed = pose.decode(entry.pose)
  if not placed then
    persist.report("the pose saved for '" .. tostring(entry.key) .. "' is not sixteen numbers")
    return false
  end
  -- The contract makes both optional: a surface fixed in place carries neither,
  -- and an arrangement cannot restore one that cannot be moved.
  local setPose, setSize = target.setPose, target.setSize
  if not setPose then
    persist.report(
      'the saved ' .. tostring(entry.kind) .. " '" .. tostring(entry.key) .. "' matched something that cannot be moved"
    )
    return false
  end
  setPose(target, placed)

  if entry.width or entry.height then
    if setSize then
      setSize(target, entry.width, entry.height)
    else
      -- The pose went, so the entry was applied and this reports rather than
      -- refuses. What it must not do is drop the size in silence: the surface
      -- comes back in the right place at the wrong size, which reads as the
      -- arrangement having been saved wrong.
      persist.report(
        'the saved '
          .. tostring(entry.kind)
          .. " '"
          .. tostring(entry.key)
          .. "' carries a size and matched something that cannot be resized"
      )
    end
  end
  for _, name in ipairs(entry.tags or {}) do
    local found = tag.find(name) or tag.new(name, nil)
    found:add(target)
  end
  return true
end

-- Puts `panels` back where the arrangement says they were.
--
-- Returns the panels it placed and the entries it could not, and reports each of
-- the latter. A saved arrangement may name a monitor that is unplugged or an
-- application that is not running, and a configuration that refused to load
-- because a cable moved is worse than one that loads partially and says so.
--
-- Panels are matched by kind, key, and slot, with slots counted in the order
-- `panels` were given. The rules source is what places a window that opens after
-- this ran; this is for the panels a configuration made itself, which is every
-- monitor panel.
function persist.restore(
  file: format.File | format.Loaded | nil,
  panels: { read [number]: Placed }
): ({ Placed }, { Entry })
  local arrangement = persist.arrangementOf(file)
  local available = slotsFor(arrangement)

  local restored: { Placed } = {}
  local matched: { [Entry]: boolean } = {}
  local counts: { [string]: number } = {}
  for index = 1, #panels do
    local target = panels[index]
    if not target.dead then
      local key = sourceKey(target)
      if key then
        local counted = target.kind .. '\0' .. key
        local slot = (counts[counted] or 0) + 1
        counts[counted] = slot
        local entry = available[slotKey(target.kind, key, slot)]
        if entry and persist.apply(entry, target) then
          restored[#restored + 1] = target
          matched[entry] = true
        end
      end
    end
  end

  local stale: { Entry } = {}
  for _, entry in ipairs(format.entries(arrangement)) do
    if not matched[entry] then
      stale[#stale + 1] = entry
      persist.report('nothing matched the saved ' .. tostring(entry.kind) .. " '" .. tostring(entry.key) .. "'")
    end
  end
  return restored, stale
end

-- A `mullion.rules` source that places a window where the arrangement says.
--
-- Each window takes the next unused entry for its `appId`, and the assignment is
-- kept by `win.id` so that resolving the same window twice does not consume two.
-- `win.id` is stable for a window's whole life and across a soft reload
-- (docs/lua-api.md#per-window-properties); it names nothing across a restart,
-- which is why the file is keyed on `appId` and not on it.
--
-- `file` is an arrangement, a load, or nothing, per `persist.arrangementOf`.
function persist.source(file): (window: lunette.Window) -> Properties?
  local available = slotsFor(file)
  local assigned: { [any]: Entry } = {}
  local counts: { [string]: number } = {}

  return function(window: lunette.Window): Properties?
    local appId = window.appId
    if type(appId) ~= 'string' or appId == '' then
      return nil
    end

    local identity = window.id
    if identity ~= nil and assigned[identity] then
      return persist.properties(assigned[identity])
    end

    local slot = (counts[appId] or 0) + 1
    counts[appId] = slot
    local entry = available[slotKey('window', appId, slot)]
    if not entry then
      return nil
    end
    if identity ~= nil then
      assigned[identity] = entry
    end
    return persist.properties(entry)
  end
end

-- Registers the restore source with `mullion.rules`.
--
-- `file` is an arrangement, a load, or nothing, per `persist.arrangementOf`, so
-- that `persist.install(persist.load())` is what a configuration writes.
--
-- `precedence` defaults to `persist.PRECEDENCE`, which is above the rules table.
-- Passing a lower one is how a configuration says that its rules should beat
-- what the user last dragged the window to.
function persist.install(file: format.File | format.Loaded | nil, precedence: number?)
  rules.addSource(persist.SOURCE, precedence or persist.PRECEDENCE, persist.source(file))
end

-- Where the arrangement is kept, as an absolute path.
--
-- Asked for rather than assumed: the save directory derives from the identity
-- and the source is the configuration directory, so the two are not the same
-- place and guessing would write into the user's configuration.
function persist.path(filesystem: Filesystem?): string
  filesystem = filesystem or defaultFilesystem()
  return filesystem.getSaveDirectory() .. '/' .. persist.FILE
end

-- Reads the arrangement from the save directory.
--
-- An absent file is an empty arrangement rather than an error: a first run has
-- saved nothing, and that is the ordinary case rather than the exceptional one.
--
-- `filesystem` is the seam. It defaults to `lovr.filesystem` and takes anything
-- carrying `read`, `write`, and `getSaveDirectory`, so the cases about an absent
-- or unwritable file do not depend on the state of a real directory.
function persist.load(filesystem: Filesystem?): format.Loaded
  filesystem = filesystem or defaultFilesystem()

  local text = filesystem.read(persist.FILE)
  if not text then
    declined = nil
    return format.empty()
  end

  local loaded: format.Loaded = format.read(text)
  if loaded.kind == 'broken' then
    local notice = persist.path(filesystem) .. ' could not be read: ' .. loaded.message .. ', so it is left alone'
    declined = notice
    persist.report(notice)
  elseif loaded.kind == 'fromTheFuture' then
    local notice = persist.path(filesystem)
      .. ' was written by version '
      .. loaded.found
      .. ', and this mullion writes version '
      .. loaded.supported
      .. ', so it is left alone'
    declined = notice
    persist.report(notice)
  else
    declined = nil
  end
  for _, message in ipairs(loaded.skipped) do
    persist.report(message)
  end
  return loaded
end

-- Why a save would be refused, or nothing.
--
-- Set by the last `load` that could not use what was on disk, and readable so
-- that a configuration can say so in its own words, or ask the user, rather than
-- only discovering it from a save that answered false.
function persist.declined()
  return declined
end

-- Writes an arrangement to the save directory.
--
-- Takes an arrangement rather than a table, so a load from a later version —
-- which yields none — has nothing to pass here. That is half of the
-- old-writer-with-new-data guard, and it is a type rather than a check.
--
-- The other half is this refusal, which the type cannot make: `capture` builds
-- an arrangement out of live panels and knows nothing about what was read, so a
-- session that declined a newer file and then saved on quit would overwrite it
-- with what this version can represent. `options.force` is how a caller that has
-- decided to overwrite it anyway says so, and it is deliberately a word rather
-- than a second load.
function persist.save(file: format.File, filesystem: Filesystem?, options: { force: boolean? }?): (boolean, string?)
  filesystem = filesystem or defaultFilesystem()

  -- Validate the value before checking the refusal, so the error names the actual
  -- invalid input.
  if not format.isFile(file) then
    error('mullion.persist: an arrangement is one this module made, not a ' .. type(file), 2)
  end
  if declined and not (options and options.force) then
    return false, declined
  end

  local text = format.render(file)
  if not filesystem.write(persist.FILE, text) then
    return false, persist.path(filesystem) .. ' could not be written'
  end
  -- A successful write clears the refusal. Otherwise a forced save would leave
  -- later saves refused after this version already replaced the newer file.
  declined = nil
  return true, nil
end

-- Clears the declined load state at teardown.
function persist.teardown()
  declined = nil
end

-- What a panel's source is known by across a restart, or nothing.
function sourceKey(target: Placed): string?
  -- Keep the branches explicit: a window without an `appId` must not fall back to
  -- its compositor-local `id`, which is not stable across restarts. Check `source`
  -- for both presence and liveness because `Placed` may be a configuration-owned
  -- object rather than a live handle.
  local key: (string | number)?
  if target.kind == 'window' then
    local source = target.source
    if not source or source.dead then
      return nil
    end
    key = source.appId
  elseif target.kind == 'monitor' then
    local source = target.source
    if not source or source.dead then
      return nil
    end
    key = source.id
  end

  if type(key) ~= 'string' or key == '' then
    return nil
  end
  return key
end

-- Every entry, keyed by kind, key, and slot.
function slotsFor(file: format.File | format.Loaded | nil): { [string]: Entry }
  local available: { [string]: Entry } = {}
  for _, entry in ipairs(format.entries(persist.arrangementOf(file))) do
    available[slotKey(entry.kind, entry.key, entry.slot)] = entry
  end
  return available
end

-- How an entry is looked up. A nul between the parts, so that a key holding
-- whatever a monitor's make and model happen to be cannot collide with another
-- by running into the slot.
function slotKey(kind: string, key: string, slot: number)
  return kind .. '\0' .. key .. '\0' .. slot
end

-- Registered by name, so that a module body running a second time — which is
-- what a soft reload does — leaves one hook rather than two.
teardown.register('mullion.persist', persist.teardown)

return persist

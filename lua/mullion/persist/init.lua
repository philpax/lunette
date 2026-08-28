-- Arrangements that remain after the process ends.
--
-- This is the part of docs/stdlib.md's tier 3 that remains after a restart. The
-- native property store keeps live per-window state across a soft reload, which
-- discards the Lua state and keeps the compositor. The module persists
-- arrangements across a hard restart, which discards the compositor too. The
-- two are different lifetimes and different mechanisms, and neither replaces
-- the other. A `WindowId` names nothing after a restart, so the file is keyed
-- on a window's `appId` plus a slot, and on a monitor's saved identity.
--
-- A mirrored screen has no per-source native store. `lunette.claimLayer` and
-- the property store take a window and nothing else, so a monitor panel's
-- hand-placed pose has no store elsewhere. That is a gap in the native
-- API. Until the gap closes, nothing else keeps a mirrored screen where the
-- user put it.
--
-- Restore is a source for `mullion.rules`, not a special case inside it. After
-- a restart a window that was hand-placed comes back where it was, and a window
-- opening fresh is placed by rule. The two results come from two sources, and
-- the sources' precedence determines which one applies; neither result depends
-- on the other's ordering.
--
-- `mullion.persist.format` holds the file's text and its versions, and it is
-- pure. The module is the shell: it reads and writes, reports what it could
-- not use, and turns entries into panels. The format's surface is re-exported,
-- so a configuration requires one module.
--
-- The file is written to `lovr.filesystem`'s save directory. The directory
-- derives from the identity, and the configuration directory is the source, so
-- the save path is not the config path.
--
-- The module holds no arrangement of its own; a file is a value a caller
-- keeps. It records whether the last load could be used. That record stops a
-- save built from live panels overwriting a file this version cannot read,
-- and the teardown hook discards it. The rules source is for `mullion.rules`
-- to discard, and that module's hook does.

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
-- carrying the same fields. The type is a shape shared by both, not
-- `mullion.panel`'s type. The entry's key is read from `source`: a window's
-- `appId` or a monitor's `id`, per `sourceKey`. A `Placed` is over something,
-- and its size in metres is known.
--
-- `Placed` is `mullion.interaction`'s surface contract plus the fields the
-- module adds, not a shape of its own. The intersection narrows `kind` to the
-- two backed forms. A keyboard and a button that a configuration drew are
-- surfaces over nothing, and an arrangement cannot hold one of them; there is
-- nothing to key it on. The intersection also narrows `pose`, `width`, and
-- `height` from the contract's optionals, because a panel always has all three.
export type Placed = pointing.Surface & {
  read kind: panel.Kind,
  read pose: Mat4,
  read width: number,
  read height: number,
}

-- What the module supplies to `mullion.rules`. The name is the module's own
-- for that module's evaluated form; an arrangement holds values, not rules.
type Properties = rules.Resolved
type Filesystem = {
  read: (string) -> string?,
  write: (string, string) -> boolean,
  getSaveDirectory: () -> string,
}

-- Declared at the top and defined below the public API, so the public API
-- reads first.
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

-- Why the last load could not be used, or nothing.
--
-- The from-the-future guard is a type at load time. A load from a later
-- version carries no arrangement, so there is nothing to hand `save`. `capture`
-- is a second constructor of an arrangement, and it builds from live panels;
-- the read file does not reach the constructor. A session that declined a
-- newer file and then quit would write this version's arrangement over it. That
-- is the old-writer-with-new-data corruption. The module records the refusal.
--
-- A load that could be used clears it, so a user who moves the newer file away
-- regains saving on the next start.
local declined: string? = nil

-- The format's surface, so a configuration requires one module. The versions
-- and the text are documented in `mullion.persist.format`.
persist.CURRENT_VERSION = format.CURRENT_VERSION
persist.newFile = format.newFile
persist.isFile = format.isFile
persist.isLoaded = format.isLoaded
persist.entries = format.entries
persist.read = format.read
persist.render = format.render

-- Where the arrangement is kept, under the save directory.
--
-- The file has no `.lua` extension. `etc/xdg/lunette/conf.lua` sets
-- `t.saveprecedence = false`, so the save directory is mounted behind the
-- standard library. A file that could never be resolved as a module does not
-- rely on that setting.
persist.FILE = 'arrangement.state'

-- Where `install` registers the restore source.
--
-- Above `mullion.rules.DEFAULT_PRECEDENCE`, so a saved pose takes precedence
-- over the rule that would otherwise have placed the window. A configuration
-- that makes the rules win passes a lower number.
persist.PRECEDENCE = 200

-- The name `install` registers under.
persist.SOURCE = 'mullion.persist'

-- Where a stale or unreadable entry is reported.
--
-- Replaceable, so error handling can route a report wherever it routes
-- everything else, and so a spec can capture one without printing it. The
-- default logs the message, and the host routes it to its own diagnostics.
-- Every report is a warning: a saved entry that could not be honoured is lost
-- state, not a failure the session cannot continue past.
function persist.report(message)
  local log = lovr.log
  if log then
    log(message, 'warn', 'mullion.persist')
  end
end

-- The arrangement in `value`, which is an arrangement, a load, or nothing.
--
-- `load` returns a load, and the functions that place panels take the
-- arrangement from inside it. The module unwraps once, not at every call site.
-- `persist.install(persist.load())` is the call a configuration writes.
-- Requiring a configuration to spell out `:forSession() or persist.newFile {}`
-- would drop the `or` and error on the first file it cannot read.
--
-- A load carrying no arrangement returns an empty one. There is nothing to
-- restore from a file this version cannot read, and a session that starts with
-- nothing saved is the ordinary first run.
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
-- A panel whose source carries no identity is reported and left out. Writing
-- it under an empty key would restore it onto the first source that also had
-- none.
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
-- and handing it through unchanged keeps one encoding.
function persist.properties(entry: Entry): Properties
  return {
    pose = entry.pose,
    width = entry.width,
    height = entry.height,
    tags = entry.tags,
  }
end

-- Applies `entry` to `target`, reporting whether it applied.
function persist.apply(entry: Entry, target: Placed): boolean
  if target.dead then
    return false
  end

  local placed = pose.decode(entry.pose)
  if not placed then
    persist.report("the pose saved for '" .. tostring(entry.key) .. "' is not sixteen numbers")
    return false
  end
  -- The contract makes both optional. A surface fixed in place carries neither,
  -- and no arrangement can restore a surface that cannot be moved.
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
      -- The pose applied, so the entry is applied. The size must not be dropped
      -- in silence: the surface comes back in the right place at the wrong size,
      -- and that reads as the arrangement having been saved wrong.
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

-- Restores `panels` from the arrangement.
--
-- Returns the panels it placed and the entries it could not, and reports each
-- of the latter. A saved arrangement may name a monitor that is unplugged or
-- an application that is not running. Refusing the whole load because a cable
-- moved is worse than loading partially and reporting the unmatched entries.
--
-- Panels are matched by kind, key, and slot, with slots counted in the order
-- `panels` were given. The rules source places a window that opens after this
-- function ran; this is for the panels a configuration made itself, which is
-- every monitor panel.
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

-- A `mullion.rules` source that places a window from the arrangement.
--
-- Each window takes the next unused entry for its `appId`, and the assignment
-- is kept by `win.id`, so resolving the same window twice does not consume two.
-- `win.id` is stable for a window's whole life and across a soft reload
-- (docs/lua-api.md#per-window-properties) and names nothing across a restart,
-- so the file is keyed on `appId`, not on `win.id`.
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
-- `file` is an arrangement, a load, or nothing, per `persist.arrangementOf`,
-- so `persist.install(persist.load())` is the call a configuration writes.
--
-- `precedence` defaults to `persist.PRECEDENCE`, which is above the rules
-- table. Passing a lower one makes the configuration's rules take precedence
-- over where the user last dragged the window.
function persist.install(file: format.File | format.Loaded | nil, precedence: number?)
  rules.addSource(persist.SOURCE, precedence or persist.PRECEDENCE, persist.source(file))
end

-- Where the arrangement is kept, as an absolute path.
--
-- The save directory derives from the identity; the source is the
-- configuration directory. Guessing that the save path is the config path
-- would write into the user's configuration.
function persist.path(filesystem: Filesystem?): string
  filesystem = filesystem or defaultFilesystem()
  return filesystem.getSaveDirectory() .. '/' .. persist.FILE
end

-- Reads the arrangement from the save directory.
--
-- An absent file is an empty arrangement, not an error. A first run has saved
-- nothing, and that is the ordinary case.
--
-- `filesystem` is the seam. It defaults to `lovr.filesystem` and takes anything
-- carrying `read`, `write`, and `getSaveDirectory`, so the cases about an
-- absent or unwritable file do not depend on the state of a real directory.
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
-- Set by the last `load` that could not use what was on disk, and readable, so
-- a configuration can state the refusal in its own words or ask the user. The
-- alternative is discovering the refusal from a save that returned false.
function persist.declined()
  return declined
end

-- Writes an arrangement to the save directory.
--
-- Takes an arrangement, not a table, so a load from a later version yields
-- no arrangement and has nothing to pass to `save`. That is half of the
-- old-writer-with-new-data guard, and it is a type, not a check.
--
-- The other half is this refusal, which the type cannot make. `capture` builds
-- an arrangement out of live panels and receives no information about what was
-- read, so a session that declined a newer file and then saved on quit would
-- overwrite it with what this version can represent. `options.force` is how a
-- caller that has decided to overwrite it expresses that; the option is a word,
-- not a second load.
function persist.save(file: format.File, filesystem: Filesystem?, options: { force: boolean? }?): (boolean, string?)
  filesystem = filesystem or defaultFilesystem()

  -- Checked before the refusal, so a caller holding the wrong kind of value
  -- is told about that and not about a file it never looked at.
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
  -- A successful write is the module's own proof of what is on disk, the same
  -- evidence a load that could be used supplies. Without it a forced save leaves
  -- the refusal active, and every later save in the session is refused over a
  -- newer file this one has already overwritten.
  declined = nil
  return true, nil
end

-- Clears the record of the declined load.
--
-- Registered as the module's teardown hook. A soft reload discards the Lua
-- state and re-runs the configuration, which loads the file again; that load
-- sets the refusal again. The old state's refusal does not carry over.
function persist.teardown()
  declined = nil
end

-- What a panel's source is known by across a restart, or nothing.
function sourceKey(target: Placed): string?
  -- The branch reads each field through its own case; an `and`/`or` chain
  -- would fall through to the monitor identity for a window whose client set
  -- no `appId`. A window also carries an `id`, so the fall-through would key
  -- the window on the compositor's identifier, which names nothing after a
  -- restart. The per-kind branch also narrows the source to the handle that
  -- kind names.
  --
  -- `source` is tested for presence as well as for life. `Placed` is satisfied
  -- by an object of a configuration's own, and the type states what kind it is;
  -- it does not state that the object carries a handle.
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

-- How an entry is looked up. A nul separates the parts, so a key holding
-- whatever a monitor's make and model happen to be cannot collide with another
-- entry by joining onto the slot.
function slotKey(kind: string, key: string, slot: number)
  return kind .. '\0' .. key .. '\0' .. slot
end

-- Registered by name, so a module body running a second time leaves one hook,
-- not two. A soft reload runs the body again.
teardown.register('mullion.persist', persist.teardown)

return persist

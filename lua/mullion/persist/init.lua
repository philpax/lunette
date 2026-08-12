-- Arrangements that outlive the process.
--
-- docs/stdlib.md's tier 3, the part that survives a restart. The native property
-- store keeps live per-window state across a soft reload, which discards the Lua
-- state and keeps the compositor; this keeps what is worth keeping across a hard
-- restart, which discards the compositor too. The two are different lifetimes
-- and different mechanisms, and neither replaces the other: a `WindowId` names
-- nothing after a restart, so what is written here is keyed on something the
-- compositor did not mint — a window's `appId` plus a slot, and a monitor's
-- saved identity.
--
-- A mirrored screen has no per-source native store at all: `lunette.claimLayer`
-- and the property store both take a window and nothing else, so a monitor
-- panel's hand-placed pose has nowhere to live but this file. That is a gap in
-- the native API rather than a decision made here, and until it closes this is
-- the only thing keeping a mirrored screen where the user put it.
--
-- Restore is a source for `mullion.rules` rather than a special case inside it.
-- After a restart a window that was hand-placed should come back where it was,
-- and a window opening fresh should be placed by rule; the two answers arrive
-- from two sources and the configuration declares which wins, rather than one
-- being buried in the other's ordering.
--
-- `mullion.persist.format` is the file's text and its versions, and it is pure.
-- This half is the shell: it reads and writes, reports what it could not use,
-- and turns entries into panels. The format's surface is re-exported here, so a
-- configuration requires one module.
--
-- The file is written to `lovr.filesystem`'s save directory, which derives from
-- the identity rather than from the source: the configuration directory is the
-- source, so the save path is not the config path and is asked for rather than
-- assumed.
--
-- This module holds no arrangement of its own — a file is a value a caller keeps
-- — but it does remember whether the last load could be used, which is what
-- stops a save built from live panels overwriting a file this version cannot
-- read. That memory is what its teardown hook discards. The rules source it
-- installs is `mullion.rules`'s to discard, and that module's hook does.

local format = require '@mullion/persist/format'
local pose = require '@mullion/pose'
local rules = require '@mullion/rules'
local tag = require '@mullion/tag'
local teardown = require '@mullion/teardown'

local persist = {}

-- One entry as an arrangement holds it, matching `mullion.persist.format`.
type Entry = {
  kind: string,
  key: string,
  slot: number,
  pose: string,
  width: number?,
  height: number?,
  tags: { string },
}

-- Declared here and defined below the public API, so the file reads
-- surface-first.
local sourceKey, slotsFor, slotKey

-- Why the last load could not be used, or nothing.
--
-- The from-the-future guard is a type as far as a load is concerned: a load from
-- a later version carries no arrangement, so there is nothing to hand `save`.
-- But `capture` is a second constructor of one, and it builds from live panels
-- rather than from what was read — so a session that declined a newer file and
-- then quit would write this version's arrangement over it, which is the
-- old-writer-with-new-data corruption arriving through the back door. This is
-- the memory that refusal needs.
--
-- Cleared by a load that could be used, so a user who moves the newer file away
-- has saving back on the next start rather than for the rest of time.
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
-- Replaceable, so that Phase 7's error handling can route it wherever it routes
-- everything else, and so that a spec can capture it rather than printing it.
-- The default logs the message, which the host routes to its own diagnostics.
-- Every report here is a warning: a saved entry that could not be honoured is
-- lost state rather than a failure the session cannot continue past.
function persist.report(message)
  lovr.log(message, 'warn', 'mullion.persist')
end

-- The arrangement in `value`, which is an arrangement, a load, or nothing.
--
-- `load` answers a load and the functions that place panels want the
-- arrangement inside it, so the unwrapping happens here rather than at every
-- call site. `persist.install(persist.load())` is the shape a configuration
-- reaches for, and one made to spell out `:forSession() or persist.newFile {}`
-- is one that drops the `or` and raises on the first file it cannot read.
--
-- A load carrying no arrangement — broken, or from a later version — answers an
-- empty one. There is nothing to restore from a file this version cannot read,
-- and a session that starts with nothing saved is the ordinary first run.
function persist.arrangementOf(value)
  if value == nil then
    return format.newFile {}
  end
  if format.isFile(value) then
    return value
  end
  if format.isLoaded(value) then
    return value:forSession() or format.newFile {}
  end
  error('mullion.persist: an arrangement is one this module made, not a ' .. type(value), 2)
end

-- The arrangement `panels` are in.
--
-- A panel whose source carries no identity is reported and left out. Writing it
-- under an empty key would restore it onto the first source that also had none.
function persist.capture(panels)
  local entries, counts = {}, {}
  for _, target in ipairs(panels) do
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
function persist.tagsOf(target)
  local names = {}
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
function persist.properties(entry): { pose: string, width: number?, height: number?, tags: { string } }
  return {
    pose = entry.pose,
    width = entry.width,
    height = entry.height,
    tags = entry.tags,
  }
end

-- Puts `target` back where `entry` says it was, reporting whether it went.
function persist.apply(entry, target)
  if target.dead then
    return false
  end

  local placed = pose.decode(entry.pose)
  if not placed then
    persist.report("the pose saved for '" .. tostring(entry.key) .. "' is not sixteen numbers")
    return false
  end
  target:setPose(placed)

  if entry.width or entry.height then
    target:setSize(entry.width, entry.height)
  end
  for _, name in ipairs(entry.tags or {}) do
    local found = tag.find(name) or tag.new(name)
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
function persist.restore(file, panels)
  local arrangement = persist.arrangementOf(file)
  local available = slotsFor(arrangement)

  local restored, matched, counts = {}, {}, {}
  for _, target in ipairs(panels) do
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

  local stale = {}
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
function persist.source(file)
  local available = slotsFor(file)
  local assigned: { [any]: Entry } = {}
  local counts: { [string]: number } = {}

  return function(window): { pose: string, width: number?, height: number?, tags: { string } }?
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
function persist.install(file, precedence)
  rules.addSource(persist.SOURCE, precedence or persist.PRECEDENCE, persist.source(file))
end

-- Where the arrangement is kept, as an absolute path.
--
-- Asked for rather than assumed: the save directory derives from the identity
-- and the source is the configuration directory, so the two are not the same
-- place and guessing would write into the user's configuration.
function persist.path(filesystem)
  filesystem = filesystem or lovr.filesystem
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
function persist.load(filesystem)
  filesystem = filesystem or lovr.filesystem

  local text = filesystem.read(persist.FILE)
  if not text then
    declined = nil
    return format.empty()
  end

  local loaded = format.read(text)
  if loaded.kind == 'broken' then
    local notice = persist.path(filesystem) .. ' could not be read: ' .. loaded.message .. ', so it is left alone'
    declined = notice
    persist.report(notice)
  elseif loaded.kind == 'fromTheFuture' then
    local found: number = loaded.found :: any
    local supported: number = loaded.supported :: any
    local notice = persist.path(filesystem)
      .. ' was written by version '
      .. found
      .. ', and this mullion writes version '
      .. supported
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
function persist.save(file, filesystem, options): (boolean, string?)
  filesystem = filesystem or lovr.filesystem

  -- Checked before the refusal, so a caller holding the wrong kind of value
  -- hears about that rather than about a file it never looked at.
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
  -- A write is this module's own proof of what is on disk, which is the same
  -- evidence a load that could be used supplies. Without this a forced save
  -- leaves the refusal armed, so every later save in the session is refused over
  -- a newer file this one has already overwritten.
  declined = nil
  return true
end

-- Forgets which load was declined.
--
-- Registered as this module's teardown hook. A soft reload discards the Lua
-- state and re-runs the configuration, which loads the file again; the refusal
-- is re-armed by that load rather than inherited from the old state's.
function persist.teardown()
  declined = nil
end

-- What a panel's source is known by across a restart, or nothing.
function sourceKey(target): string?
  local source = target.source
  if not source or source.dead then
    return nil
  end

  -- Spelt out rather than as an `and`/`or`, which would fall through to the
  -- monitor identity for a window whose client set no `appId` — and a window
  -- also carries an `id`, so the fall-through would silently key it on the
  -- compositor's identifier, which names nothing after a restart.
  local key
  if target.kind == 'window' then
    key = source.appId
  else
    key = source.id
  end

  if type(key) ~= 'string' or key == '' then
    return nil
  end
  return key
end

-- Every entry, keyed by kind, key, and slot.
function slotsFor(file)
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

local testing = require '@testing'
local lunette = require '@lunette'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local frameContract = require '@lunette-contracts/frame'
local format = require '../private/format'
local persist = require '../private/state'
local panelsContract = require '@lunette-contracts/panels'
local rulesContract = require '@lunette-contracts/rules'
local tagsContract = require '@lunette-contracts/tags'
local placementContract = require '@lunette-contracts/placement'
local vocabulary = require '@lunette-contracts/vocabulary'

local test = testing.suite()

type Native = testing.Native
type Binding = { read save: (Binding) -> (boolean, string?), read restore: (Binding) -> number }
type BindingCallback = (Binding, plugin.Context, panelsContract.Service, Native) -> ()

local POSE = vocabulary.encodePose(lovr.math.newMat4():translate(1, 1.5, -2))

test('an arrangement round-trips placement through render and read, sizes to the last digit', function()
  local written = {
    entries = {
      {
        kind = 'window',
        key = 'terminal',
        slot = 2,
        pose = POSE,
        width = 1 / 3,
        height = 0.9,
        tags = { 'main' },
      },
      { kind = 'monitor', key = 'Acme X24 on DP-1', slot = 1, pose = POSE, tags = {} },
    },
  }
  local loaded = format.read(format.render(written))
  expect.equal(loaded.kind, 'arrangement', 'the kind')
  for index, entry in loaded.file.entries do
    local original = written.entries[index]
    for _, field in { 'kind', 'key', 'slot', 'pose', 'width', 'height' } do
      expect.equal(entry[field], original[field], 'the ' .. field .. ' of entry ' .. index)
    end
    expect.equal(entry.locked, nil, 'version three writes no input lock')
    expect.equal(table.concat(entry.tags, ','), table.concat(original.tags, ','), 'the tags of entry ' .. index)
  end
  expect.equal(#loaded.file.entries, 2, 'the entries')
end)

-- Runs `run` with a binding of a state that read `text` as the saved file, and answers the fake native API.
local function withBinding(text: string?, run: BindingCallback): Native
  local native = testing.native()
  local saveFile = lunette.saveFile
  native.events.saved = text
  local state = persist.new(persist.FILE)
  local session = testing.start { 'theme', 'panels', 'tags', 'rules', 'frame', 'placement' }
  session:use(adapter.define {
    name = 'arrangement-test',
    requires = {
      panelsContract.capability,
      tagsContract.capability,
      rulesContract.capability,
      frameContract.capability,
      placementContract.capability,
    },
    init = function(context: plugin.Context)
      local panels = context:require(panelsContract.capability)
      local tags = context:require(tagsContract.capability)
      local binding = state:bind(
        context,
        panels,
        tags,
        context:require(rulesContract.capability),
        context:require(frameContract.capability),
        nil
      )
      run(binding, context, panels, native)
    end,
  })
  session:close()
  expect.equal(lunette.saveFile, saveFile, 'session cleanup restores the public save function')
  return native
end

test('a broken file or one from a later version is refused and never overwritten', function()
  for _, text in { 'return { version = ' .. (format.VERSION + 1) .. ', entries = {} }', 'return {' } do
    local native = withBinding(
      text,
      function(binding: Binding, context: plugin.Context, panels: panelsContract.Service, _native: Native)
        local target = panels:fromWindow(context, _native.newWindow(1))
        target:setPose(lovr.math.newMat4():translate(1, 1, -2))
        local saved, message = binding:save()
        expect.equal(saved, false, 'the save')
        expect.truthy(
          message:find('written by version', 1, true) or message:find('could not be read', 1, true),
          message
        )
      end
    )
    expect.equal(native.events.saved, text, 'the bytes')
    expect.equal(native.events.writes, 0, 'the writes')
  end
end)

test('a save then a restore puts live windows back in their slots', function()
  withBinding(nil, function(binding: Binding, context: plugin.Context, panels: panelsContract.Service, native: Native)
    local first = panels:fromWindow(context, native.newWindow(1), { pose = lovr.math.newMat4():translate(-1, 1, -2) })
    local second = panels:fromWindow(context, native.newWindow(2), { pose = lovr.math.newMat4():translate(1, 1, -2) })
    expect.equal(binding:save(), true, 'the save')
    first:setPose(lovr.math.newMat4())
    second:setPose(lovr.math.newMat4())
    expect.equal(binding:restore(), 2, 'the restored panels')
    expect.near((first.pose:getPosition()), -1, 1e-5, 'the first slot')
    expect.near((second.pose:getPosition()), 1, 1e-5, 'the second slot')
  end)
end)

for _, afterReplacement in { false, true } do
  local phase = if afterReplacement then 'after replacement' else 'before writing'

  local function failSave(context: plugin.Context): plugin.Effect
    return context:acquire(context, function(): () -> ()
      local saveFile = lunette.saveFile
      lunette.saveFile = function(directory: string, name: string, contents: string): ()
        if name ~= 'arrangement.state' then
          saveFile(directory, name, contents)
          return
        end
        if afterReplacement then
          saveFile(directory, name, contents)
        end
        error('injected save failure', 0)
      end
      return function()
        lunette.saveFile = saveFile
      end
    end)
  end

  test(`a save failure {phase} keeps the latest capture for session restore`, function()
    withBinding(nil, function(binding: Binding, context: plugin.Context, panels: panelsContract.Service, native: Native)
      local target =
        panels:fromWindow(context, native.newWindow(1), { pose = lovr.math.newMat4():translate(-1, 1, -2) })
      expect.equal(binding:save(), true, 'the initial save')
      local previous = native.events.saved
      target:setPose(lovr.math.newMat4():translate(3, 1.5, -4))
      failSave(context)
      local saved, message = binding:save()
      expect.equal(saved, false, 'the failed save does not claim persistence')
      expect.truthy(message and message:find('injected save failure', 1, true), tostring(message))
      expect.equal(native.events.saved == previous, not afterReplacement, 'the replacement outcome')
      target:setPose(lovr.math.newMat4())
      expect.equal(binding:restore(), 1, 'the session capture restores the live panel')
      expect.near((target.pose:getPosition()), 3, 1e-5, 'restore uses the latest capture despite the failed write')
    end)
  end)

  test(`a save failure {phase} keeps absent entries for the next save and restore`, function()
    withBinding(nil, function(binding: Binding, context: plugin.Context, panels: panelsContract.Service, native: Native)
      local firstWindow = native.newWindow(1, 'terminal')
      local first = panels:fromWindow(context, firstWindow, { pose = lovr.math.newMat4():translate(-1, 1, -2) })
      expect.equal(binding:save(), true, 'the initial save')
      local previous = native.events.saved
      first:setPose(lovr.math.newMat4():translate(3, 1.5, -4))
      local secondWindow = native.newWindow(2, 'browser')
      local second = panels:fromWindow(context, secondWindow, { pose = lovr.math.newMat4():translate(5, 2, -6) })
      local failure = failSave(context)
      local saved, message = binding:save()
      expect.equal(saved, false, 'the failed save does not claim persistence')
      expect.truthy(message and message:find('injected save failure', 1, true), tostring(message))
      expect.equal(native.events.saved == previous, not afterReplacement, 'the replacement outcome')
      failure:dispose()
      expect.truthy(first:destroy(context), 'the updated panel disappears')
      expect.truthy(second:destroy(context), 'the newly captured panel disappears')
      expect.equal(#panels:all(), 0, 'no live panels remain to recapture')
      expect.equal(binding:save(), true, 'a later save retries the retained capture')
      local loaded = format.read(native.events.saved)
      expect.equal(loaded.kind, 'arrangement', 'the retried file')
      expect.equal(#loaded.file.entries, 2, 'the retry keeps both absent entries')
      first = panels:fromWindow(context, firstWindow, { pose = lovr.math.newMat4() })
      second = panels:fromWindow(context, secondWindow, { pose = lovr.math.newMat4() })
      expect.equal(binding:restore(), 2, 'both returning panels restore')
      expect.near((first.pose:getPosition()), 3, 1e-5, 'the updated absent entry keeps its latest pose')
      expect.near((second.pose:getPosition()), 5, 1e-5, 'the newly captured absent entry keeps its pose')
    end)
  end)
end

test('a malformed entry is refused and named while the rest loads', function()
  local text = 'return { version = 3, entries = {\n'
    .. "  { kind = 'window', key = 'terminal', slot = 1, pose = '"
    .. POSE
    .. "', tags = {} },\n"
    .. "  { kind = 'terminal', key = 'k', slot = 1, pose = 'x', tags = {} },\n"
    .. "  { kind = 'window', key = 'no slot', pose = '"
    .. POSE
    .. "', tags = {} },\n"
    .. '} }'
  local loaded = format.read(text)
  expect.equal(#loaded.file.entries, 1, 'the entries')
  expect.equal(loaded.file.entries[1].key, 'terminal', 'the entry that survived')
  expect.equal(#loaded.skipped, 2, 'the entries refused')
  expect.truthy(loaded.skipped[1]:find('window or a monitor', 1, true), loaded.skipped[1])
  expect.truthy(loaded.skipped[2]:find('has no slot', 1, true), loaded.skipped[2])
end)

test('the input lock lives only in versions one and two and migrates into the store', function()
  expect.equal(format.VERSION, 3, 'placement data alone is version three')
  local function text(version: number, lock: string): string
    return 'return { version = '
      .. version
      .. ", entries = { { kind = 'window', key = 'terminal', slot = 1, pose = '"
      .. POSE
      .. "', tags = {}, "
      .. lock
      .. ' } } }'
  end
  for _, lock in { '', 'locked = true,', 'locked = false,' } do
    local migrated = format.read(text(1, lock))
    expect.equal(migrated.file.entries[1].locked, false, 'version one always migrates unlocked')
  end
  for _, lock in { '', "locked = 'true',", 'locked = 1,' } do
    local invalid = format.read(text(2, lock))
    expect.equal(#invalid.file.entries, 0, 'a missing or nonboolean v2 lock is refused')
    expect.equal(#invalid.skipped, 1, 'the malformed lock is reported')
  end
  local current = format.read(text(3, 'locked = true,'))
  expect.equal(current.file.entries[1].locked, nil, 'version three has no lock to migrate')
end)

test('a version four file is refused as from the future', function()
  local loaded = format.read 'return { version = 4, entries = {} }'
  expect.equal(loaded.kind, 'fromTheFuture', 'the kind')
  expect.equal(loaded.found, 4, 'the version')
end)

test('lock toggles save the properties store, not the arrangement', function()
  withBinding(nil, function(binding: Binding, context: plugin.Context, panels: panelsContract.Service, native: Native)
    local first = panels:fromWindow(context, native.newWindow(1))
    local second = panels:fromWindow(context, native.newWindow(2))
    expect.truthy(first:setLocked(context, true), 'locking succeeds')
    expect.equal(native.events.writes, 0, 'the arrangement does not save a lock')
    expect.equal(native.events.fileWrites['panel-properties.saved'], 1, 'the properties store saves the lock')
    expect.truthy(second:setLocked(context, true), 'a second lock succeeds')
    expect.equal(native.events.fileWrites['panel-properties.saved'], 2, 'each toggle saves the store')
    expect.truthy(first:setLocked(context, false), 'unlocking succeeds')
    expect.equal(native.events.fileWrites['panel-properties.saved'], 3, 'unlocking saves the store')
    expect.equal(native.events.writes, 0, 'no lock toggle touches the arrangement')
  end)
end)

test('a v2 input lock migrates into the store on first bind', function()
  local text = format.render {
    entries = {
      { kind = 'window', key = 'terminal', slot = 1, pose = POSE, tags = {}, locked = true },
      { kind = 'monitor', key = 'screen-a', slot = 1, pose = POSE, tags = {}, locked = false },
    },
  }
  -- format.render writes version three without the migration field, so state the v2 shape explicitly.
  text = "return { version = 2, entries = { { kind = 'window', key = 'terminal', slot = 1, pose = '"
    .. POSE
    .. "', tags = {}, locked = true }, { kind = 'monitor', key = 'screen-a', slot = 1, pose = '"
    .. POSE
    .. "', tags = {}, locked = false } } }"
  withBinding(text, function(binding: Binding, context: plugin.Context, panels: panelsContract.Service, native: Native)
    local window = panels:fromWindow(context, native.newWindow(1))
    expect.truthy(window.locked, 'the migrated lock applies to the matching panel')
    local monitor = panels:fromMonitor(context, native.newMonitor 'screen-a')
    expect.falsy(monitor.locked, 'a migrated false lock stays unlocked')
    local stored = native.events.files['panel-properties.saved']
    expect.truthy(stored, 'the migration writes the store')
    expect.truthy(stored:find('inputLocked = true', 1, true), 'the true lock is stored')
    expect.truthy(stored:find('curveAxis = 0', 1, true), 'the migrated axis is zero')
    expect.equal(binding:save(), true, 'the arrangement saves after the migration')
    expect.truthy(native.events.saved:find('version = 3', 1, true), 'the arrangement then writes version three')
  end)
end)

test('a failed migration write leaves the v2 arrangement untouched', function()
  local text = "return { version = 2, entries = { { kind = 'window', key = 'terminal', slot = 1, pose = '"
    .. POSE
    .. "', tags = {}, locked = true } } }"
  local native = testing.native()
  native.events.saved = text
  native.events.saveFailure = 'the fixture refuses the store'
  local state = persist.new(persist.FILE)
  local session = testing.start { 'theme', 'panels', 'tags', 'rules', 'frame', 'placement' }
  session:use(adapter.define {
    name = 'arrangement-test',
    requires = {
      panelsContract.capability,
      tagsContract.capability,
      rulesContract.capability,
      frameContract.capability,
    },
    init = function(context: plugin.Context)
      local panels = context:require(panelsContract.capability)
      local binding = state:bind(
        context,
        panels,
        context:require(tagsContract.capability),
        context:require(rulesContract.capability),
        context:require(frameContract.capability),
        nil
      )
      local saved, message = binding:save()
      expect.equal(saved, false, 'the arrangement save is refused')
      expect.truthy(message and message:find('panel properties', 1, true), tostring(message))
    end,
  })
  session:close()
  expect.equal(native.events.saved, text, 'the v2 file is left alone')
  expect.equal(native.events.writes, 0, 'no arrangement write happened')
end)

return test

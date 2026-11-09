local testing = require '@testing'
local lunette = require '@lunette'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
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

test('an arrangement round-trips through render and read, sizes to the last digit', function()
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
        locked = true,
      },
      { kind = 'monitor', key = 'Acme X24 on DP-1', slot = 1, pose = POSE, tags = {}, locked = false },
    },
  }
  local loaded = format.read(format.render(written))
  expect.equal(loaded.kind, 'arrangement', 'the kind')
  for index, entry in loaded.file.entries do
    local original = written.entries[index]
    for _, field in { 'kind', 'key', 'slot', 'pose', 'width', 'height', 'locked' } do
      expect.equal(entry[field], original[field], 'the ' .. field .. ' of entry ' .. index)
    end
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
  local session = testing.start { 'theme', 'panels', 'tags', 'rules', 'placement' }
  session:use(adapter.define {
    name = 'arrangement-test',
    requires = {
      panelsContract.capability,
      tagsContract.capability,
      rulesContract.capability,
      placementContract.capability,
    },
    init = function(context: plugin.Context)
      local panels = context:require(panelsContract.capability)
      local tags = context:require(tagsContract.capability)
      local binding = state:bind(context, panels, tags, context:require(rulesContract.capability))
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
      function(binding: Binding, context: plugin.Context, panels: panelsContract.Service, native: Native)
        local target = panels:fromWindow(context, native.newWindow(1))
        target:setLocked(context, true)
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
  local text = 'return { version = 1, entries = {\n'
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

test('version two requires boolean locks and version one migrates unlocked', function()
  expect.equal(format.VERSION, 2, 'locks require a version bump so old writers refuse the file')
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
end)

test('lock toggles save immediately and direct restore does not write partial captures', function()
  withBinding(nil, function(binding: Binding, context: plugin.Context, panels: panelsContract.Service, native: Native)
    local first = panels:fromWindow(context, native.newWindow(1))
    local second = panels:fromWindow(context, native.newWindow(2))
    expect.truthy(first:setLocked(context, true), 'locking succeeds')
    expect.equal(native.events.writes, 1, 'locking saves without waiting for a drop or quit')
    local loaded = format.read(native.events.saved)
    expect.equal(loaded.file.entries[1].locked, true, 'the file captures authoritative state')
    expect.equal(loaded.file.entries[2].locked, false, 'the other panel stays unlocked')
    expect.truthy(second:setLocked(context, true), 'a second lock succeeds')
    expect.equal(native.events.writes, 2, 'each toggle saves immediately')
    expect.truthy(first:setLocked(context, false), 'unlocking succeeds')
    expect.equal(native.events.writes, 3, 'unlocking saves immediately')
    expect.equal(format.read(native.events.saved).file.entries[1].locked, false, 'false survives the file')
  end)
  local text = format.render {
    entries = {
      { kind = 'window', key = 'terminal', slot = 1, pose = POSE, tags = {}, locked = true },
      { kind = 'window', key = 'terminal', slot = 2, pose = POSE, tags = {}, locked = true },
    },
  }
  withBinding(text, function(binding: Binding, context: plugin.Context, panels: panelsContract.Service, native: Native)
    local first = panels:fromWindow(context, native.newWindow(1))
    local second = panels:fromWindow(context, native.newWindow(2))
    expect.equal(binding:restore(), 2, 'both existing panels restore')
    expect.truthy(first.locked and second.locked, 'direct restore applies both locks')
    expect.equal(native.events.writes, 0, 'restoring does not save intermediate panel state')
  end)
end)

test('late monitor and window rules restore locks without rewriting the arrangement', function()
  local text = format.render {
    entries = {
      { kind = 'window', key = 'terminal', slot = 1, pose = POSE, tags = {}, locked = true },
      { kind = 'monitor', key = 'screen-a', slot = 1, pose = POSE, tags = {}, locked = true },
    },
  }
  withBinding(text, function(_binding: Binding, context: plugin.Context, panels: panelsContract.Service, native: Native)
    local monitor = panels:fromMonitor(context, native.newMonitor 'screen-a')
    expect.truthy(monitor.locked, 'a late monitor restores directly')
    local placement = context:require(placementContract.capability)
    local window = native.newWindow(1)
    local placed = placement:place(context, { window = window })
    expect.truthy(placed.panel.locked, 'a late window receives the persisted lock through rules and placement')
    expect.equal(native.events.writes, 0, 'restoration leaves the saved file untouched')
  end)
end)

test('version one restores unlocked and the next toggle writes version two', function()
  local text = "return { version = 1, entries = { { kind = 'window', key = 'terminal', slot = 1, pose = '"
    .. POSE
    .. "', tags = {} } } }"
  withBinding(text, function(binding: Binding, context: plugin.Context, panels: panelsContract.Service, native: Native)
    local target = panels:fromWindow(context, native.newWindow(1), { locked = true })
    expect.equal(binding:restore(), 1, 'the legacy entry restores')
    expect.falsy(target.locked, 'a legacy entry restores unlocked even over a live lock')
    expect.equal(native.events.writes, 0, 'migration does not rewrite the file during restore')
    target:setLocked(context, true)
    expect.truthy(native.events.saved:find('version = 2', 1, true), 'the next toggle writes the current version')
    expect.truthy(format.read(native.events.saved).file.entries[1].locked, 'the migrated entry saves its new lock')
  end)
end)

return test

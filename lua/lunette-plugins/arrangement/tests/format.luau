local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local format = require '@lunette-plugins/arrangement/format'
local persist = require '@lunette-plugins/arrangement/state'
local panelsContract = require '@lunette-contracts/panels'
local rulesContract = require '@lunette-contracts/rules'
local tagsContract = require '@lunette-contracts/tags'
local vocabulary = require '@lunette-contracts/vocabulary'

local test = testing.suite()

local POSE = vocabulary.encodePose(lovr.math.newMat4():translate(1, 1.5, -2))

test('an arrangement round-trips through render and read, sizes to the last digit', function()
  local written = {
    entries = {
      { kind = 'window', key = 'terminal', slot = 2, pose = POSE, width = 1 / 3, height = 0.9, tags = { 'main' } },
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
    expect.equal(table.concat(entry.tags, ','), table.concat(original.tags, ','), 'the tags of entry ' .. index)
  end
  expect.equal(#loaded.file.entries, 2, 'the entries')
end)

-- Runs `run` with a binding of a state that read `text` as the saved file, and answers the fake native API.
local function withBinding(text: string?, run)
  local native = testing.native()
  native.events.saved = text
  local state = persist.new(persist.FILE)
  local session = testing.start { 'theme', 'panels', 'tags', 'rules' }
  session:use(plugin.define {
    name = 'arrangement-test',
    requires = {
      panels = panelsContract.capability,
      tags = tagsContract.capability,
      rules = rulesContract.capability,
    },
    init = function(context)
      local panels = context:require(panelsContract.capability)
      local tags = context:require(tagsContract.capability)
      local binding = state:bind(context, panels, tags, context:require(rulesContract.capability))
      run(binding, context, panels, native)
    end,
  })
  session:close()
  return native
end

test('a broken file or one from a later version is refused and never overwritten', function()
  for _, text in { 'return { version = ' .. (format.VERSION + 1) .. ', entries = {} }', 'return {' } do
    local native = withBinding(text, function(binding)
      local saved, message = binding:save()
      expect.equal(saved, false, 'the save')
      expect.truthy(message:find('written by version', 1, true) or message:find('could not be read', 1, true), message)
    end)
    expect.equal(native.events.saved, text, 'the bytes')
    expect.equal(native.events.writes, 0, 'the writes')
  end
end)

test('a save then a restore puts live windows back in their slots', function()
  withBinding(nil, function(binding, context, panels, native)
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

return test

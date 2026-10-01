-- Filesystem and refusal behavior for configuration-owned persistence state.
local expect = require '@spec/expect'
local suite = require '@spec/suite'
local plugin = require '@lunette-plugin'
local panelsContract = require '@lunette-contracts/panels'
local tagsContract = require '@lunette-contracts/tags'
local rulesContract = require '@lunette-contracts/rules'
local persist = require '@mullion/persist'

local spec = suite.new 'mullion.persist.file'

local function filesystem(text)
  local fs = { text = text, reads = 0, writes = 0, writable = true }
  function fs.read(filename)
    expect.equal(filename, 'arrangement.state', 'the read filename')
    fs.reads += 1
    return fs.text
  end
  function fs.write(filename, contents)
    expect.equal(filename, 'arrangement.state', 'the write filename')
    if not fs.writable then
      return false
    end
    fs.writes += 1
    fs.text = contents
    return true
  end
  function fs.getSaveDirectory()
    return '/a/save/directory'
  end
  return fs
end

local function newState(fs, onReport)
  local reports = {}
  local state = persist.new {
    filesystem = fs,
    report = function(message)
      reports[#reports + 1] = message
      if onReport then
        onReport(message)
      end
    end,
  }
  return state, reports
end

local function withBinding(state, run)
  local runtime = plugin.runtime()
  for _, name in ipairs { 'panels', 'tags', 'rules' } do
    runtime:use(require('@lunette-plugins/' .. name), {}):enable()
  end
  local binding, context, panels, tags
  local owner = runtime:use(
    plugin.define(
      function(value)
        return value
      end,
      { panels = panelsContract.capability, tags = tagsContract.capability, rules = rulesContract.capability },
      {},
      function(current)
        context = current
        panels = current:require(panelsContract.capability)
        tags = current:require(tagsContract.capability)
        binding = state:bind(current, panels, tags, current:require(rulesContract.capability))
      end
    ),
    {}
  )
  owner:enable()
  local ok, failure = pcall(function()
    expect.truthy(binding and binding:active(), 'the initialized binding')
    run(binding, context, panels, tags, owner)
  end)
  runtime:close()
  if not ok then
    error(failure)
  end
end

local function futureText()
  return 'return { version = ' .. (persist.CURRENT_VERSION + 1) .. ', entries = {}, future = true }'
end

spec('an absent file loads an empty arrangement without reporting', function()
  local fs = filesystem(nil)
  local state, reports = newState(fs)
  expect.equal(state:loaded().kind, 'arrangement', 'the load')
  expect.equal(#persist.entries(state:arrangement()), 0, 'the entries')
  expect.equal(fs.reads, 1, 'the reads')
  expect.equal(#reports, 0, 'the reports')
end)

spec('a future file is reported and left untouched', function()
  local text = futureText()
  local fs = filesystem(text)
  local state, reports = newState(fs)
  expect.equal(state:loaded().kind, 'fromTheFuture', 'the load')
  expect.equal(fs.text, text, 'the bytes')
  expect.equal(fs.writes, 0, 'the writes')
  expect.equal(#reports, 1, 'the reports')
  expect.truthy(reports[1]:find('written by version', 1, true), 'the report')
end)

spec('a broken file is reported rather than raising', function()
  local state, reports = newState(filesystem 'return {')
  expect.equal(state:loaded().kind, 'broken', 'the load')
  expect.truthy(state:declined():find('could not be read', 1, true), 'the refusal')
  expect.equal(#reports, 1, 'the reports')
end)

spec('skipped entries are reported when state is constructed', function()
  local state, reports = newState(filesystem "return { version = 1, entries = { { kind = 'nothing' } } }")
  expect.equal(#persist.entries(state:arrangement()), 0, 'the entries')
  expect.equal(#reports, 1, 'the reports')
  expect.truthy(reports[1]:find('window or a monitor', 1, true), 'the report')
end)

spec('an unwritable file returns failure without changing the arrangement', function()
  local fs = filesystem(nil)
  local state = newState(fs)
  local arrangement = state:arrangement()
  fs.writable = false
  withBinding(state, function(binding)
    local saved, message = binding:save()
    expect.equal(saved, false, 'the save')
    expect.truthy(message:find('could not be written', 1, true), 'the failure')
    expect.equal(state:arrangement(), arrangement, 'the retained arrangement')
  end)
  expect.equal(fs.writes, 0, 'the writes')
end)

for _, text in ipairs { futureText(), 'return {' } do
  spec('ordinary save leaves refused bytes untouched: ' .. text, function()
    local fs = filesystem(text)
    local state = newState(fs)
    withBinding(state, function(binding)
      local saved, message = binding:save()
      expect.equal(saved, false, 'the save')
      expect.equal(message, state:declined(), 'the refusal')
    end)
    expect.equal(fs.text, text, 'the bytes')
    expect.equal(fs.writes, 0, 'the writes')
  end)
end

spec('successful force save clears refusal and permits later ordinary saves', function()
  local fs = filesystem(futureText())
  local state = newState(fs)
  withBinding(state, function(binding)
    expect.equal(binding:save { force = true }, true, 'the forced save')
    expect.falsy(state:declined(), 'the cleared refusal')
    expect.equal(binding:save(), true, 'the ordinary save')
  end)
  expect.equal(fs.writes, 2, 'the writes')
  expect.equal(fs.text, persist.render(state:arrangement()), 'the rendered bytes')
  expect.equal(state:loaded().kind, 'fromTheFuture', 'the original load result')
end)

spec('failed force save retains refusal and original bytes', function()
  local text = futureText()
  local fs = filesystem(text)
  local state = newState(fs)
  local refusal = state:declined()
  fs.writable = false
  withBinding(state, function(binding)
    expect.equal(binding:save { force = true }, false, 'the forced save')
    expect.equal(state:declined(), refusal, 'the retained refusal')
  end)
  expect.equal(fs.text, text, 'the bytes')
end)

spec('new state can read a replacement file without changing an existing refusal', function()
  local fs = filesystem(futureText())
  local refused = newState(fs)
  fs.text = persist.render(persist.newFile {})
  local readable = newState(fs)
  expect.truthy(refused:declined(), 'the existing refusal')
  expect.falsy(readable:declined(), 'the new readable state')
  withBinding(readable, function(binding)
    expect.equal(binding:save(), true, 'the save')
  end)
end)

spec('the path uses the save directory and no module extension', function()
  local fs = filesystem(nil)
  expect.equal(persist.path(fs), '/a/save/directory/arrangement.state', 'the path')
  expect.falsy(persist.FILE:find '%.lua$', 'the module extension')
end)

spec('saved bytes restore pose, size, and tags in a new configuration state', function()
  local fs = filesystem(nil)
  local state = newState(fs)
  withBinding(state, function(binding, context, panels, tags)
    local panel = panels:fromMonitor(context, { id = 'fixture.monitor', dead = false, width = 1920, height = 1080 }, {
      pose = lovr.math.newMat4():translate(-0.5, 1.75, -2.25),
      width = 1.6,
    })
    tags:new(context, 'main'):add(context, panel)
    expect.equal(binding:save(), true, 'the save')
  end)
  local recovered = newState(fs)
  withBinding(recovered, function(binding, context, panels, tags)
    -- One binding per source name: the first is released before the panel
    -- exists, so the second restores it at bind.
    binding:dispose()
    local panel = panels:fromMonitor(context, { id = 'fixture.monitor', dead = false, width = 1920, height = 1080 })
    local second = recovered:bind(context, panels, tags, context:require(rulesContract.capability))
    local x, y, z = panel.pose:getPosition()
    expect.near(x, -0.5, 1e-5, 'x')
    expect.near(y, 1.75, 1e-5, 'y')
    expect.near(z, -2.25, 1e-5, 'z')
    expect.near(panel.width, 1.6, 1e-5, 'the width')
    expect.truthy(tags:find('main'):has(panel), 'the restored tag')
    second:dispose()
  end)
  expect.equal(fs.reads, 2, 'one read per state')
end)

spec('disposed bindings cannot save even with force', function()
  local fs = filesystem(nil)
  withBinding(newState(fs), function(binding)
    binding:dispose()
    binding:dispose()
    local saved, message = binding:save { force = true }
    expect.equal(saved, false, 'the save')
    expect.truthy(message:find('no longer active', 1, true), 'the failure')
  end)
  expect.equal(fs.writes, 0, 'the writes')
end)

spec('save rechecks the active scope after reporting during capture', function()
  local fs = filesystem(nil)
  local owner
  local state = newState(fs, function()
    owner:disable()
  end)
  withBinding(state, function(binding, context, panels, _tags, currentOwner)
    owner = currentOwner
    panels:fromMonitor(context, { id = 8, dead = false, width = 1920, height = 1080 })
    expect.equal(binding:save(), false, 'the suspended save')
  end)
  expect.equal(fs.writes, 0, 'the writes after suspension')
end)

spec('the default adapter routes reads and writes through the save filesystem', function()
  local previous = lovr.filesystem
  local fs = filesystem(nil)
  lovr.filesystem = fs
  local ok, failure = pcall(function()
    local state = persist.new()
    expect.equal(persist.path(), '/a/save/directory/arrangement.state', 'the default path')
    withBinding(state, function(binding)
      expect.equal(binding:save(), true, 'the default write')
    end)
    expect.equal(fs.reads, 1, 'the default read')
    expect.equal(fs.writes, 1, 'the default write count')
    expect.equal(fs.text, persist.render(state:arrangement()), 'the format-one bytes')
  end)
  lovr.filesystem = previous
  if not ok then
    error(failure)
  end
end)

return spec

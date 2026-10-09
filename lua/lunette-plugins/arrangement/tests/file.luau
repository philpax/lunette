local testing = require '@testing'
local expect = testing.expect
local rulesContract = require '@lunette-contracts/rules'
local arrangement = require '@lunette-plugins/arrangement/format'
local persist = require '@lunette-plugins/arrangement/state'
local fixture = require './support/fixture'

local test = testing.suite()

local function filesystem(text, name)
  local expected = name or 'arrangement.state'
  local fs = { text = text, reads = 0, writes = 0, writable = true }
  function fs.read(filename)
    expect.equal(filename, expected, 'the read filename')
    fs.reads += 1
    return fs.text
  end
  function fs.write(filename, contents)
    expect.equal(filename, expected, 'the write filename')
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

local function withBinding(state, run, extend)
  fixture.run({ bind = state, extend = extend }, function(env)
    expect.truthy(env.binding and env.binding:active(), 'the initialized binding')
    run(env.binding, env.context, env.panels, env.tags, env.owner, env.providers)
  end)
end

local function futureText()
  return 'return { version = ' .. (arrangement.CURRENT_VERSION + 1) .. ', entries = {}, future = true }'
end

test('an absent file loads an empty arrangement without reporting', function()
  local fs = filesystem(nil)
  local state, reports = newState(fs)
  expect.equal(state:loaded().kind, 'arrangement', 'the load')
  expect.equal(#arrangement.entries(state:arrangement()), 0, 'the entries')
  expect.equal(fs.reads, 1, 'the reads')
  expect.equal(#reports, 0, 'the reports')
end)

test('a future file is reported and left untouched', function()
  local text = futureText()
  local fs = filesystem(text)
  local state, reports = newState(fs)
  expect.equal(state:loaded().kind, 'fromTheFuture', 'the load')
  expect.equal(fs.text, text, 'the bytes')
  expect.equal(fs.writes, 0, 'the writes')
  expect.equal(#reports, 1, 'the reports')
  expect.truthy(reports[1]:find('written by version', 1, true), 'the report')
end)

test('a broken file is reported rather than raising', function()
  local state, reports = newState(filesystem 'return {')
  expect.equal(state:loaded().kind, 'broken', 'the load')
  expect.truthy(state:declined():find('could not be read', 1, true), 'the refusal')
  expect.equal(#reports, 1, 'the reports')
end)

test('skipped entries are reported when state is constructed', function()
  local state, reports = newState(filesystem "return { version = 1, entries = { { kind = 'nothing' } } }")
  expect.equal(#arrangement.entries(state:arrangement()), 0, 'the entries')
  expect.equal(#reports, 1, 'the reports')
  expect.truthy(reports[1]:find('window or a monitor', 1, true), 'the report')
end)

test('an unwritable file returns failure without changing the arrangement', function()
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
  test('ordinary save leaves refused bytes untouched: ' .. text, function()
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

test('new state can read a replacement file without changing an existing refusal', function()
  local fs = filesystem(futureText())
  local refused = newState(fs)
  fs.text = arrangement.render(arrangement.newFile {})
  local readable = newState(fs)
  expect.truthy(refused:declined(), 'the existing refusal')
  expect.falsy(readable:declined(), 'the new readable state')
  withBinding(readable, function(binding)
    expect.equal(binding:save(), true, 'the save')
  end)
end)

test('the path uses the save directory and no module extension', function()
  local fs = filesystem(nil)
  expect.equal(persist.path(fs), '/a/save/directory/arrangement.state', 'the path')
  expect.falsy(persist.FILE:find '%.luau?$', 'the module extension')
end)

test('saved bytes restore pose, size, and tags in a new configuration state', function()
  local fs = filesystem(nil)
  local state = newState(fs)
  withBinding(state, function(binding, context, panels, tags)
    local panel = panels:fromMonitor(context, { id = 'fixture.monitor', dead = false, width = 1920, height = 1080 }, {
      pose = lovr.math.newMat4():translate(-0.5, 1.75, -2.25),
      width = 1.6,
    })
    tags:hold(context, { name = 'main' }):add(context, panel)
    expect.equal(binding:save(), true, 'the save')
  end)
  local recovered = newState(fs)
  withBinding(recovered, function(_binding, context, panels, tags)
    local panel = panels:fromMonitor(context, { id = 'fixture.monitor', dead = false, width = 1920, height = 1080 })
    local x, y, z = panel.pose:getPosition()
    expect.near(x, -0.5, 1e-5, 'x')
    expect.near(y, 1.75, 1e-5, 'y')
    expect.near(z, -2.25, 1e-5, 'z')
    expect.near(panel.width, 1.6, 1e-5, 'the width')
    expect.truthy(tags:find('main'):has(panel), 'the restored tag')
  end)
  expect.equal(fs.reads, 2, 'one read per state')
end)

test('a saved entry nothing matches is reported once per load', function()
  local fs = filesystem(nil)
  withBinding(newState(fs), function(binding, context, panels)
    panels:fromMonitor(context, { id = 'fixture.unplugged', dead = false, width = 1920, height = 1080 })
    expect.equal(binding:save(), true, 'the save')
  end)
  local function stale(reports)
    local count = 0
    for _, message in ipairs(reports) do
      if message:find("nothing matched the saved monitor 'fixture.unplugged'", 1, true) then
        count += 1
      end
    end
    return count
  end
  local recovered, reports = newState(fs)
  withBinding(recovered, function(binding, _context, _panels, _tags, owner)
    expect.equal(stale(reports), 1, 'the bind reports it')
    binding:restore()
    binding:restore()
    expect.equal(stale(reports), 1, 'a restore does not report it again')
    owner:disable()
    owner:enable()
    expect.equal(stale(reports), 1, 'a binding of the same load does not report it again')
  end)
  local reloaded, fresh = newState(fs)
  withBinding(reloaded, function() end)
  expect.equal(stale(fresh), 1, 'a new load reports it again')
end)

test('save rechecks the active scope after reporting during capture', function()
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

test('an unloading binding refuses every save while its source is still registered', function()
  local fs = filesystem(nil)
  local ran, failure = false, nil
  withBinding(newState(fs), function(binding, context, _panels, _tags, owner)
    local rules = context:require(rulesContract.capability)
    expect.equal(#testing.ruleSources(rules), 2, 'the binding source and the caller rules')
    owner:disable()
    expect.truthy(ran, 'the later inverse ran')
    if failure then
      error(failure)
    end
    expect.falsy(binding:active(), 'the binding after unload')
    expect.equal(#testing.ruleSources(rules), 0, 'the binding source and the caller rules are removed exactly')
  end, function(current, binding)
    local rules = current:require(rulesContract.capability)
    rules:setRules(current, { rules = { { properties = { width = 1 } } } })
    -- This inverse runs before the binding's inverse.
    current:effect(function()
      return function()
        ran = true
        local ok, raised = pcall(function()
          expect.falsy(current:active(), 'the context is inactive before its inverses run')
          expect.equal(#testing.ruleSources(rules), 2, 'the persistence source is still registered')
          expect.falsy(binding:save(), 'an ordinary save')
        end)
        if not ok then
          failure = raised
        end
      end
    end)
  end)
  expect.equal(fs.writes, 0, 'the writes')
end)

test('neither the state nor a binding kept past its activation retains a retired service', function()
  withBinding(newState(filesystem(nil)), function(binding, _context, panels, _tags, _owner, providers)
    local retired = setmetatable({ panels }, { __mode = 'v' })
    panels = nil
    providers.panels:disable()
    expect.falsy(binding:active(), 'the binding of the suspended consumer')
    providers.panels:enable()
    collectgarbage 'collect'
    collectgarbage 'collect'
    expect.equal(retired[1], nil, 'the retired panels service')
  end)
end)

test('the default adapter routes reads and writes through the save filesystem', function()
  local native = testing.native()
  local state = persist.new()
  expect.equal(persist.path(), '/fixture/arrangement.state', 'the default path')
  fixture.run({ bind = state, native = native }, function(env)
    expect.equal(env.binding:save(), true, 'the default write')
  end)
  expect.equal(native.events.reads, 1, 'the default read')
  expect.equal(native.events.writes, 1, 'the default write count')
  expect.equal(native.events.saved, arrangement.render(state:arrangement()), 'the format-one bytes')
end)

test('an empty file name raises at construction', function()
  expect.raises(function()
    persist.new { file = '' }
  end, 'desktop.persist', 'the malformed dependency')
end)

return test

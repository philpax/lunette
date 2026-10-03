-- Filesystem and refusal behavior for configuration-owned persistence state.
local expect = require '@spec/expect'
local suite = require '@spec/suite'
local plugin = require '@lunette-plugin'
local panelsContract = require '@lunette-contracts/panels'
local tagsContract = require '@lunette-contracts/tags'
local rulesContract = require '@lunette-contracts/rules'
local persist = require '@lunette-desktop/persist'

local spec = suite.new 'lunette-desktop.persist.file'

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

-- Binds the state in a consumer's initializer, which then calls `extend`, when given, with its context and
-- the binding. `run` receives the binding, the consumer's context and services, its instance, and the
-- provider instances by name.
local function withBinding(state, run, extend)
  local runtime = plugin.runtime()
  local providers = {}
  for _, name in ipairs { 'panels', 'tags', 'rules' } do
    providers[name] = runtime:use(require('@lunette-plugins/' .. name).definition, {})
    providers[name]:enable()
  end
  local binding, context, panels, tags
  local owner = runtime:use(
    plugin.define {
      name = 'file-spec-1',
      requires = {
        panels = panelsContract.capability,
        tags = tagsContract.capability,
        rules = rulesContract.capability,
      },
      init = function(current)
        context = current
        panels = current:require(panelsContract.capability)
        tags = current:require(tagsContract.capability)
        binding = state:bind(current, panels, tags, current:require(rulesContract.capability))
        if extend then
          extend(current, binding)
        end
      end,
    },
    {}
  )
  owner:enable()
  local ok, failure = pcall(function()
    expect.truthy(binding and binding:active(), 'the initialized binding')
    run(binding, context, panels, tags, owner, providers)
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
  expect.falsy(persist.FILE:find '%.luau?$', 'the module extension')
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
  withBinding(recovered, function(_binding, context, panels, tags)
    -- The binding restores a panel that appears after it as the panel appears.
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

spec('a saved entry nothing matches is reported once per load', function()
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

spec('an unloading binding refuses every save while its source is still registered', function()
  local fs = filesystem(nil)
  local ran, failure = false, nil
  withBinding(newState(fs), function(binding, context, _panels, _tags, owner)
    local rules = context:require(rulesContract.capability)
    expect.equal(#rules:sources(), 2, 'the binding source and the caller rules')
    owner:disable()
    expect.truthy(ran, 'the later inverse ran')
    if failure then
      error(failure)
    end
    expect.falsy(binding:active(), 'the binding after unload')
    expect.equal(#rules:sources(), 0, 'the binding source and the caller rules are removed exactly')
  end, function(current, binding)
    local rules = current:require(rulesContract.capability)
    rules:setRules(current, { rules = { { properties = { width = 1 } } } })
    -- Registered after the bind, so its inverse runs before the binding's own.
    current:effect(function()
      return function()
        ran = true
        local ok, raised = pcall(function()
          expect.falsy(current:active(), 'the context is inactive before its inverses run')
          expect.equal(#rules:sources(), 2, 'the persistence source is still registered')
          expect.falsy(binding:save(), 'an ordinary save')
          expect.falsy(binding:save { force = true }, 'a forced save')
        end)
        if not ok then
          failure = raised
        end
      end
    end)
  end)
  expect.equal(fs.writes, 0, 'the writes')
end)

spec('neither the state nor a binding kept past its activation retains a retired service', function()
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

-- A format of a configuration's own, answering fromTheFuture for a later version.
local LINES_VERSION = 1
local lines = {
  read = function(text)
    local version = tonumber(text:match '^lines (%d+)\n')
    if not version then
      return persist.broken 'no version line'
    end
    if version > LINES_VERSION then
      return persist.fromTheFuture { found = version, supported = LINES_VERSION }
    end
    local entries = {}
    for kind, key, slot, pose in text:gmatch '(%a+)\t([^\t]+)\t(%d+)\t([^\n]+)\n' do
      entries[#entries + 1] = { kind = kind, key = key, slot = tonumber(slot), pose = pose, tags = {} }
    end
    return persist.arrangement { file = persist.newFile(entries), version = version }
  end,
  render = function(file)
    local out = { 'lines ' .. LINES_VERSION }
    for _, entry in ipairs(persist.entries(file)) do
      out[#out + 1] = table.concat({ entry.kind, entry.key, tostring(entry.slot), entry.pose }, '\t')
    end
    return table.concat(out, '\n') .. '\n'
  end,
}

spec('a named file in another format round-trips the arrangement', function()
  local fs = filesystem(nil, 'profile.lines')
  local state = persist.new { filesystem = fs, file = 'profile.lines', format = lines }
  expect.equal(persist.path(fs, 'profile.lines'), '/a/save/directory/profile.lines', 'the named path')
  withBinding(state, function(binding, context, panels)
    panels:fromMonitor(context, { id = 'fixture.monitor', dead = false, width = 1920, height = 1080 }, {
      pose = lovr.math.newMat4():translate(1, 2, 3),
    })
    expect.equal(binding:save(), true, 'the save')
  end)
  expect.truthy(fs.text:find '^lines 1\nmonitor\tfixture.monitor\t1\t', 'the format wrote the file: ' .. fs.text)
  local recovered = persist.new { filesystem = fs, file = 'profile.lines', format = lines }
  local entries = persist.entries(recovered:arrangement())
  expect.equal(#entries, 1, 'the entries read back')
  expect.equal(entries[1].key, 'fixture.monitor', 'the key read back')
end)

spec('a format that reports a later version leaves the file alone', function()
  local fs = filesystem('lines 7\n', 'profile.lines')
  local reports = {}
  local state = persist.new {
    filesystem = fs,
    file = 'profile.lines',
    format = lines,
    report = function(message)
      reports[#reports + 1] = message
    end,
  }
  expect.equal(state:loaded().kind, 'fromTheFuture', 'the load')
  expect.truthy(state:declined():find('written by version 7', 1, true), 'the refusal')
  withBinding(state, function(binding)
    expect.equal(binding:save(), false, 'the refused save')
  end)
  expect.equal(fs.text, 'lines 7\n', 'the bytes')
end)

spec('a format whose read raises or answers no load is a broken file', function()
  for _, read in ipairs {
    function()
      error 'unreadable'
    end,
    function()
      return { kind = 'arrangement' }
    end,
  } do
    local state = persist.new {
      filesystem = filesystem 'anything',
      format = { read = read, render = lines.render },
      report = function() end,
    }
    expect.equal(state:loaded().kind, 'broken', 'the load')
  end
end)

spec('a malformed file, format, or key function raises at construction', function()
  for _, dependencies in ipairs {
    { file = '' },
    { format = { read = lines.read } },
    { keyFor = 'title' },
  } do
    expect.raises(function()
      persist.new(dependencies)
    end, 'desktop.persist', 'the malformed dependency')
  end
end)

spec('a key function keys windows by title instead of application', function()
  local fs = filesystem(nil)
  local state = persist.new {
    filesystem = fs,
    keyFor = function(target)
      if target.kind == 'window' then
        return target.source.title
      end
      return persist.defaultKey(target)
    end,
  }
  local function terminal(id, title)
    return {
      id = id,
      appId = 'terminal',
      title = title,
      dead = false,
      width = 800,
      height = 600,
      getProperty = function() end,
    }
  end
  withBinding(state, function(binding)
    local source = persist.source(
      persist.newFile {
        { kind = 'window', key = 'build', slot = 1, pose = '1 0 0 0 0 1 0 0 0 0 1 0 4 5 6 1', tags = {} },
      },
      persist.slots(function(target)
        return target.source.title
      end)
    )
    expect.truthy(source(terminal(1, 'build')), 'the window titled build has the entry')
    expect.falsy(source(terminal(2, 'editor')), 'another title of the same application does not')
    expect.truthy(binding:active(), 'the binding')
  end)
end)

return spec

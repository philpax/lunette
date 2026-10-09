local testing = require '@testing'
local expect = testing.expect
local rulesContract = require '@lunette-contracts/rules'
local arrangement = require '@lunette-plugins/arrangement/format'
local persist = require '@lunette-plugins/arrangement/state'
local fixture = require './support/fixture'

local test = testing.suite()

-- A fresh fake native API holding `text` as the saved file, and a state that read it.
local function newState(text)
  local native = testing.native()
  native.events.saved = text
  return persist.new(persist.FILE), native
end

local function reports(native)
  local messages = {}
  for _, entry in ipairs(native.events.logs) do
    messages[#messages + 1] = entry[1]
  end
  return messages
end

local function withBinding(state, native, run, extend)
  fixture.run({ bind = state, native = native, extend = extend }, function(env)
    run(env.binding, env.context, env.panels, env.tags, env.owner)
  end)
end

local function futureText()
  return 'return { version = ' .. (arrangement.VERSION + 1) .. ', entries = {}, future = true }'
end

test('an absent file loads an empty arrangement without reporting', function()
  local state, native = newState(nil)
  expect.equal(native.events.reads, 1, 'the reads')
  expect.equal(#reports(native), 0, 'the reports')
  withBinding(state, native, function(binding)
    expect.equal(binding:restore(), 0, 'the restored panels')
  end)
end)

test('a future file is reported and left untouched', function()
  local text = futureText()
  local state, native = newState(text)
  expect.equal(#reports(native), 1, 'the reports')
  expect.truthy(reports(native)[1]:find('written by version', 1, true), 'the report')
  withBinding(state, native, function(binding)
    local saved, message = binding:save()
    expect.equal(saved, false, 'the save')
    expect.truthy(message:find('written by version', 1, true), 'the refusal')
  end)
  expect.equal(native.events.saved, text, 'the bytes')
  expect.equal(native.events.writes, 0, 'the writes')
end)

test('a broken file is reported and left untouched', function()
  local state, native = newState 'return {'
  expect.equal(#reports(native), 1, 'the reports')
  expect.truthy(reports(native)[1]:find('/fixture/arrangement.state could not be read', 1, true), 'the report')
  withBinding(state, native, function(binding)
    local saved, message = binding:save()
    expect.equal(saved, false, 'the save')
    expect.truthy(message:find('could not be read', 1, true), 'the refusal')
  end)
  expect.equal(native.events.saved, 'return {', 'the bytes')
  expect.equal(native.events.writes, 0, 'the writes')
end)

test('refused entries are reported when state is constructed', function()
  local _, native = newState "return { version = 1, entries = { { kind = 'nothing' } } }"
  expect.equal(#reports(native), 1, 'the reports')
  expect.truthy(reports(native)[1]:find('window or a monitor', 1, true), 'the report')
end)

test('an unwritable file returns failure', function()
  local state, native = newState(nil)
  native.events.writeMode = 'refuse'
  withBinding(state, native, function(binding)
    local saved, message = binding:save()
    expect.equal(saved, false, 'the save')
    expect.truthy(message:find('could not be written', 1, true), 'the failure')
  end)
end)

test('saved bytes restore pose, size, and tags in a new configuration state', function()
  local state, native = newState(nil)
  withBinding(state, native, function(binding, context, panels, tags)
    local panel = panels:fromMonitor(context, { id = 'fixture.monitor', dead = false, width = 1920, height = 1080 }, {
      pose = lovr.math.newMat4():translate(-0.5, 1.75, -2.25),
      width = 1.6,
    })
    tags:hold(context, { name = 'main' }):add(context, panel)
    expect.equal(binding:save(), true, 'the save')
  end)
  local recovered, again = newState(native.events.saved)
  withBinding(recovered, again, function(_binding, context, panels, tags)
    local panel = panels:fromMonitor(context, { id = 'fixture.monitor', dead = false, width = 1920, height = 1080 })
    local x, y, z = panel.pose:getPosition()
    expect.near(x, -0.5, 1e-5, 'x')
    expect.near(y, 1.75, 1e-5, 'y')
    expect.near(z, -2.25, 1e-5, 'z')
    expect.near(panel.width, 1.6, 1e-5, 'the width')
    expect.truthy(tags:find('main'):has(panel), 'the restored tag')
  end)
end)

test('a saved entry nothing matches is reported once per load', function()
  local state, native = newState(nil)
  withBinding(state, native, function(binding, context, panels)
    panels:fromMonitor(context, { id = 'fixture.unplugged', dead = false, width = 1920, height = 1080 })
    expect.equal(binding:save(), true, 'the save')
  end)
  local function stale(current)
    local count = 0
    for _, message in ipairs(reports(current)) do
      if message:find("nothing matched the saved monitor 'fixture.unplugged'", 1, true) then
        count += 1
      end
    end
    return count
  end
  local text = native.events.saved
  local recovered, again = newState(text)
  withBinding(recovered, again, function(binding, _context, _panels, _tags, owner)
    expect.equal(stale(again), 1, 'the bind reports it')
    binding:restore()
    binding:restore()
    expect.equal(stale(again), 1, 'a restore does not report it again')
    owner:disable()
    owner:enable()
    expect.equal(stale(again), 1, 'a binding of the same load does not report it again')
  end)
  local reloaded, fresh = newState(text)
  withBinding(reloaded, fresh, function() end)
  expect.equal(stale(fresh), 1, 'a new load reports it again')
end)

test('an unloading binding refuses every save while its source is still registered', function()
  local state, native = newState(nil)
  local ran, failure = false, nil
  withBinding(state, native, function(binding, context, _panels, _tags, owner)
    local rules = context:require(rulesContract.capability)
    expect.equal(#testing.ruleSources(rules), 2, 'the binding source and the caller rules')
    owner:disable()
    expect.truthy(ran, 'the later inverse ran')
    if failure then
      error(failure)
    end
    expect.falsy(binding:save(), 'a save after unload')
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
  expect.equal(native.events.writes, 0, 'the writes')
end)

return test

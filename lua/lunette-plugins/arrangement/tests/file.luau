local testing = require '@testing'
local expect = testing.expect
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

local function withBinding(state, native, run)
  fixture.run({ bind = state, native = native }, function(env)
    run(env.binding, env.context, env.panels, env.tags, env.owner)
  end)
end

test('a future, broken, or refused file is reported, and a future or broken one is never overwritten', function()
  for _, text in { 'return { version = ' .. (arrangement.VERSION + 1) .. ', entries = {} }', 'return {' } do
    local state, native = newState(text)
    expect.equal(#reports(native), 1, 'the reports')
    withBinding(state, native, function(binding)
      local saved, message = binding:save()
      expect.equal(saved, false, 'the save')
      expect.truthy(message:find('written by version', 1, true) or message:find('could not be read', 1, true), message)
    end)
    expect.equal(native.events.saved, text, 'the bytes')
    expect.equal(native.events.writes, 0, 'the writes')
  end
  local _, native = newState "return { version = 1, entries = { { kind = 'nothing' } } }"
  expect.equal(#reports(native), 1, 'the reports')
  expect.truthy(reports(native)[1]:find('window or a monitor', 1, true), 'the refused entry')
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

return test

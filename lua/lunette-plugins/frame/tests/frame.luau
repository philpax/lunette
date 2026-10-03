-- Covers the frame provider and the LÖVR callbacks `frame.install` binds to it: update and draw phase order,
-- key and text bindings consuming before delivery, handlers ending with their owner, registration checks,
-- one frame activation at a time, the callbacks during a frame outage, and quit stopping the runtime.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local frame = require '@lunette-plugins/frame'
local frameContract = require '@lunette-contracts/frame'

local test = testing.suite()

-- The frame provider over the fake native API, with the callbacks installed as `testing.boot` installs them,
-- except that quit also counts each stop in `env.stopped`.
local function start()
  local env = { native = testing.native(), stopped = 0 }
  frame.install {
    start = function() end,
    stop = function()
      env.stopped += 1
      env.session.runtime:close()
    end,
  }
  env.session = testing.start { 'frame' }
  -- The session draws with the fake's pass and checks the fake's resources when it closes.
  env.session.native = env.native
  return env
end

-- A consumer of the frame service, whose initializer registers through it.
local function consumer(env, name, register)
  local instance = env.session:use(plugin.define {
    name = name,
    requires = { frame = frameContract.capability },
    init = function(context)
      register(context, context:require(frameContract.capability))
    end,
  })
  expect.equal(instance:state(), 'active', name)
  return instance
end

local function recorder(trace)
  return function(label)
    return function()
      trace[#trace + 1] = label
    end
  end
end

test('update and draw run input, scene, pointing, then overlay, and by order then registration', function()
  local env = start()
  local trace = {}
  local record = recorder(trace)
  consumer(env, 'frame-order', function(context, service)
    service:onUpdate(context, { phase = 'overlay', run = record 'overlay' })
    service:onUpdate(context, { phase = 'scene', order = 1, run = record 'scene+1' })
    service:onUpdate(context, { phase = 'pointing', run = record 'pointing' })
    service:onUpdate(context, { phase = 'scene', run = record 'scene-first' })
    service:onUpdate(context, { phase = 'scene', run = record 'scene-second' })
    service:onUpdate(context, { phase = 'input', order = 5, run = record 'input' })
    service:onUpdate(context, { phase = 'scene', order = -1, run = record 'scene-1' })
    service:onDraw(context, { phase = 'overlay', run = record 'draw-overlay' })
    service:onDraw(context, { phase = 'scene', run = record 'draw-scene' })
    service:onDraw(context, { phase = 'input', run = record 'draw-input' })
    service:onDraw(context, { phase = 'pointing', run = record 'draw-pointing' })
  end)
  env.session:update()
  expect.equal(
    table.concat(trace, ' '),
    'input scene-1 scene-first scene-second scene+1 pointing overlay',
    'the update order'
  )
  table.clear(trace)
  expect.equal(env.session:draw(), false, 'draw does not veto the pass')
  expect.equal(table.concat(trace, ' '), 'draw-input draw-scene draw-pointing draw-overlay', 'the draw order')
  env.session:close()
end)

test('handlers end with their owner, and a re-enabled owner registers once', function()
  local env = start()
  local trace = {}
  local record = recorder(trace)
  local owner = consumer(env, 'frame-owner', function(context, service)
    service:onUpdate(context, { phase = 'scene', run = record 'update' })
    service:onDraw(context, { phase = 'scene', run = record 'draw' })
  end)
  owner:disable()
  env.session:update()
  env.session:draw()
  expect.equal(#trace, 0, 'the handlers of an unloaded owner')
  owner:enable()
  env.session:update()
  env.session:draw()
  expect.equal(table.concat(trace, ' '), 'update draw', 'the handlers of the re-enabled owner')
  env.session:close()
end)

test('a binding consumes a key or text before delivery, and a raising binding consumes nothing', function()
  local env = start()
  local keys, texts = {}, {}
  local frozen = true
  local bindings = consumer(env, 'frame-keys', function(context, service)
    service:onKey(context, {
      phase = 'delivery',
      run = function(event)
        keys[#keys + 1] = 'deliver:' .. event.key
      end,
    })
    service:onKey(context, {
      order = 1,
      run = function(event)
        keys[#keys + 1] = 'bind:' .. event.key
        return event.key == 'f9'
      end,
    })
    service:onKey(context, {
      run = function(event)
        if event.key == 'f9' then
          expect.equal(event.scancode, 67, 'the scancode')
          expect.equal(event.isRepeat, true, 'the repeat flag')
        end
        frozen = frozen and not pcall(function()
          event.key = 'changed'
        end)
        if event.key == 'f1' then
          error 'binding failure'
        end
      end,
    })
    service:onText(context, {
      phase = 'delivery',
      run = function(event)
        texts[#texts + 1] = 'deliver:' .. event.text .. ':' .. event.code
      end,
    })
    service:onText(context, {
      phase = 'binding',
      run = function(event)
        texts[#texts + 1] = 'bind:' .. event.text
        return event.text == 'x'
      end,
    })
  end)
  lovr.keypressed('f9', 67, true)
  expect.equal(table.concat(keys, ' '), 'bind:f9', 'a consumed key reaches no later handler')
  table.clear(keys)
  lovr.keypressed('a', 4, false)
  expect.equal(table.concat(keys, ' '), 'bind:a deliver:a', 'an unconsumed key')
  table.clear(keys)
  lovr.keypressed('f1', 58, false)
  expect.equal(table.concat(keys, ' '), 'bind:f1 deliver:f1', 'a raising binding consumes nothing')
  local reported = env.native.events.reported
  expect.equal(#reported, 1, 'the reports')
  expect.truthy(reported[1].message:find('lovr.keypressed: ', 1, true), reported[1].message)
  expect.truthy(reported[1].message:find('binding failure', 1, true), reported[1].message)
  expect.truthy(frozen, 'a key event is read-only, so a handler cannot change what later ones see')
  lovr.textinput('x', 120)
  lovr.textinput('y', 121)
  expect.equal(table.concat(texts, ' '), 'bind:x bind:y deliver:y:121', 'the text handlers')
  bindings:disable()
  table.clear(keys)
  lovr.keypressed('a', 4, false)
  expect.equal(#keys, 0, 'key handlers end with their owner')
  env.session:close()
end)

test('a handler disposed by an earlier one in the same dispatch is skipped', function()
  local env = start()
  local runs = 0
  consumer(env, 'frame-dispose', function(context, service)
    local later
    service:onUpdate(context, {
      phase = 'input',
      run = function()
        if later then
          later:dispose()
          later = nil
        end
      end,
    })
    later = service:onUpdate(context, {
      phase = 'scene',
      run = function()
        runs += 1
      end,
    })
  end)
  env.session:update()
  expect.equal(runs, 0, 'the runs of the disposed handler')
  env.session:close()
end)

test('a malformed registration raises with an error naming the problem', function()
  local env = start()
  consumer(env, 'frame-checks', function(context, service)
    expect.raises(function()
      service:onUpdate(context, { run = function() end })
    end, 'frame onUpdate: phase is one of input, scene, pointing, overlay, not nil', 'a missing phase')
    expect.raises(function()
      service:onUpdate(context, { phase = 'scene', oder = 1, run = function() end })
    end, 'frame onUpdate: unknown field oder', 'an unknown field')
    expect.raises(function()
      service:onText(context, function() end)
    end, 'frame onText: a handler is a table of fields, not a function', 'a handler given as a function')
  end)
  env.session:close()
end)

test('one frame activation receives the callbacks at a time', function()
  local env = start()
  local other = plugin.runtime()
  local second = other:use(frame.definition, {})
  second:enable()
  expect.equal(second:state(), 'failed', 'the second frame activation')
  expect.truthy(
    tostring(second:diagnostic()):find('another frame activation already receives the LÖVR callbacks', 1, true),
    tostring(second:diagnostic())
  )
  local reports = testing.takeReports()
  expect.equal(#reports, 1, 'the reports')
  expect.truthy(reports[1]:find('another frame activation', 1, true), reports[1])
  other:close()
  env.session:close()
end)

test('while the frame provider is out the callbacks do nothing, and recovery restores its dependents', function()
  local env = start()
  local ticks = 0
  local ticking = consumer(env, 'frame-outage', function(context, service)
    service:onUpdate(context, {
      phase = 'scene',
      run = function()
        ticks += 1
      end,
    })
  end)
  local provider = env.session.instances.frame
  provider:disable()
  expect.truthy(ticking:state() ~= 'active', 'the dependent during the outage')
  env.session:update()
  expect.equal(env.session:draw(), false, 'draw during the outage')
  lovr.keypressed('a', 4, false)
  expect.equal(ticks, 0, 'the ticks during the outage')
  provider:enable()
  expect.equal(ticking:state(), 'active', 'the dependent after recovery')
  env.session:update()
  expect.equal(ticks, 1, 'the ticks after recovery')
  env.session:close()
end)

test('quit runs its handlers, then stops the runtime', function()
  local env = start()
  local trace = {}
  consumer(env, 'frame-quit', function(context, service)
    service:onQuit(context, {
      run = function()
        trace[#trace + 1] = 'quit'
        expect.equal(env.stopped, 0, 'the stops before the quit handler')
      end,
    })
  end)
  expect.equal(env.session:quit(), false, 'quit does not veto')
  expect.equal(table.concat(trace, ' '), 'quit', 'the quit handlers')
  expect.equal(env.stopped, 1, 'the stops')
  expect.truthy(env.session.instances.frame:state() ~= 'active', 'the frame provider after quit')
  env.session:close()
end)

return test

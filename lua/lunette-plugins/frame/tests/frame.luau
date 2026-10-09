local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
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
  env.session.native = env.native
  return env
end

local function consumer(env, name, register)
  return env.session:use(adapter.define {
    name = name,
    requires = { frameContract.capability },
    init = function(context)
      register(context, context:require(frameContract.capability))
    end,
  })
end

local function recorder(trace)
  return function(label)
    return function()
      trace[#trace + 1] = label
    end
  end
end

test('update and draw run by phase, then order, then registration', function()
  local env = start()
  local trace = {}
  local record = recorder(trace)
  consumer(env, 'frame-order', function(context, service)
    service:onUpdate(context, { phase = 'overlay', run = record 'overlay' })
    service:onUpdate(context, { phase = 'scene', order = 1, run = record 'scene+1' })
    service:onUpdate(context, { phase = 'pointing', run = record 'pointing' })
    service:onUpdate(context, { phase = 'scene', run = record 'scene-first' })
    service:onUpdate(context, { phase = 'scene', run = record 'scene-second' })
    service:onUpdate(context, { phase = 'input', run = record 'input' })
    service:onDraw(context, { phase = 'overlay', run = record 'draw-overlay' })
    service:onDraw(context, { phase = 'scene', run = record 'draw-scene' })
  end)
  env.session:update()
  expect.equal(table.concat(trace, ' '), 'input scene-first scene-second scene+1 pointing overlay', 'the update order')
  table.clear(trace)
  expect.equal(env.session:draw(), false, 'draw does not veto the pass')
  expect.equal(table.concat(trace, ' '), 'draw-scene draw-overlay', 'the draw order')
  env.session:close()
end)

test('a binding consumes a key or text before delivery, and handlers end with their owner', function()
  local env = start()
  local keys, texts = {}, {}
  local bindings = consumer(env, 'frame-keys', function(context, service)
    service:onKey(context, {
      phase = 'delivery',
      run = function(event)
        keys[#keys + 1] = 'deliver:' .. event.key
      end,
    })
    service:onKey(context, {
      run = function(event)
        keys[#keys + 1] = 'bind:' .. event.key
        if event.key == 'f1' then
          error 'binding failure'
        end
        return event.key == 'f9'
      end,
    })
    service:onText(context, {
      phase = 'delivery',
      run = function(event)
        texts[#texts + 1] = 'deliver:' .. event.text
      end,
    })
    service:onText(context, {
      run = function(event)
        texts[#texts + 1] = 'bind:' .. event.text
        return event.text == 'x'
      end,
    })
  end)
  lovr.keypressed('f9', 67, true)
  lovr.keypressed('a', 4, false)
  lovr.keypressed('f1', 58, false)
  expect.equal(table.concat(keys, ' '), 'bind:f9 bind:a deliver:a bind:f1 deliver:f1', 'a raise consumes nothing')
  expect.equal(#env.native.events.reported, 1, 'the raising binding is reported')
  lovr.textinput('x', 120)
  lovr.textinput('y', 121)
  expect.equal(table.concat(texts, ' '), 'bind:x bind:y deliver:y', 'the text handlers')
  bindings:disable()
  table.clear(keys)
  lovr.keypressed('a', 4, false)
  expect.equal(#keys, 0, 'key handlers end with their owner')
  env.session:close()
end)

test('batch observers run first, and a consumed binding key or blockText blocks text until the next update', function()
  local env = start()
  local trace, batches, events = {}, {}, {}
  local service
  consumer(env, 'frame-batches', function(context, frameService)
    service = frameService
    service:onBatch(context, {
      run = function(batch)
        batches[#batches + 1] = batch
        trace[#trace + 1] = if batch.textBlocked then 'blocked' else 'batch'
      end,
    })
    service:onKey(context, {
      run = function(event)
        trace[#trace + 1] = 'key'
        events[#events + 1] = event
        return event.key == 'q'
      end,
    })
  end)
  lovr.keypressed(
    'a',
    4,
    false,
    { shift = true, control = false, alt = false, super = false, capsLock = false, numLock = true }
  )
  lovr.keypressed('q', 16, false)
  expect.equal(table.concat(trace, ' '), 'batch key key blocked', 'the observer runs before the binding')
  expect.equal(batches[2].id, batches[1].id, 'blocking text does not advance the batch')
  expect.equal(events[2].batch, batches[1].id, 'events carry their batch')
  expect.equal(events[1].code, 30, 'the key carries its evdev code')
  expect.equal(table.concat(events[1].modifiers, ','), 'shift,numLock', 'the key carries the host modifiers')
  expect.truthy(events[1].physicalModifiers.numLock, 'the key carries the host snapshot')

  env.session:update()
  expect.equal(batches[3].id, batches[1].id + 1, 'the update advances the batch')
  expect.equal(batches[3].textBlocked, false, 'the next update restores text')
  expect.falsy(service:blockText(batches[1].id), 'a previous batch cannot block text')
  expect.truthy(service:blockText(batches[3].id), 'the current batch can')
  expect.equal(batches[4].textBlocked, true, 'blockText notifies the observers')
  env.session:close()
end)

test('a malformed registration raises an error naming the problem', function()
  local env = start()
  consumer(env, 'frame-checks', function(context, service)
    expect.raises(function()
      service:onUpdate(context, { run = function() end })
    end, 'frame onUpdate: phase is one of input, scene, pointing, overlay, not nil', 'a missing phase')
  end)
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
  env.session:close()
end)

return test

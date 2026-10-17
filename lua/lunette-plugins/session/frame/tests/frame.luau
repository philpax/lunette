local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local frame = require '../'
local frameContract = require '@lunette-contracts/frame'

local test = testing.suite()

type Environment = { native: testing.Native, stopped: number, session: testing.Session? }
type Register = (plugin.Context, frameContract.Service) -> ()

-- The frame provider over the fake native API, with the callbacks installed as `testing.boot` installs them,
-- except that quit also counts each stop in `env.stopped`.
local function start(): Environment
  local env: Environment = { native = testing.native(), stopped = 0 }
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

local function consumer(env: Environment, name: string, register: Register): adapter.Instance<{}>
  return env.session:use(adapter.define {
    name = name,
    requires = { frameContract.capability },
    init = function(context: plugin.Context)
      register(context, context:require(frameContract.capability))
    end,
  })
end

local function recorder(trace: { string }): (string) -> () -> ()
  return function(label: string): () -> ()
    return function()
      trace[#trace + 1] = label
    end
  end
end

test('update and draw run by phase, then order, then registration', function()
  local env = start()
  local trace: { string } = {}
  local record = recorder(trace)
  consumer(env, 'frame-order', function(context: plugin.Context, service: frameContract.Service)
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
  local keys: { string } = {}
  local texts: { string } = {}
  local bindings = consumer(env, 'frame-keys', function(context: plugin.Context, service: frameContract.Service)
    service:onKey(context, {
      phase = 'delivery',
      run = function(event: frameContract.HostKeyEvent)
        keys[#keys + 1] = 'deliver:' .. event.key
      end,
    })
    service:onKey(context, {
      run = function(event: frameContract.HostKeyEvent): boolean
        keys[#keys + 1] = 'bind:' .. event.key
        if event.key == 'f1' then
          error 'binding failure'
        end
        return event.key == 'f9'
      end,
    })
    service:onText(context, {
      phase = 'delivery',
      run = function(event: frameContract.HostTextEvent)
        texts[#texts + 1] = 'deliver:' .. event.text
      end,
    })
    service:onText(context, {
      run = function(event: frameContract.HostTextEvent): boolean
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

test('mouse handlers receive movement, buttons, and wheel in registration order and end with their owner', function()
  local env = start()
  local trace: { string } = {}
  local mice = consumer(env, 'frame-mouse', function(context: plugin.Context, service: frameContract.Service)
    service:onMouse(context, {
      run = function(event: frameContract.HostMouseEvent)
        if event.kind == 'move' then
          trace[#trace + 1] = `move:{event.x},{event.y},{event.dx},{event.dy}`
        elseif event.kind == 'press' or event.kind == 'release' then
          trace[#trace + 1] = `{event.kind}:{event.button}`
          if event.button == 2 then
            error 'mouse failure'
          end
        else
          trace[#trace + 1] = `wheel:{event.dx},{event.dy}`
        end
      end,
    })
    service:onMouse(context, {
      run = function(event: frameContract.HostMouseEvent)
        trace[#trace + 1] = 'second:' .. event.kind
        expect.truthy(table.isfrozen(event), 'the event is frozen')
      end,
    })
  end)
  lovr.mousemoved(10, 20, 3, -4)
  lovr.mousepressed(10, 20, 2)
  lovr.mousereleased(10, 20, 1)
  lovr.wheelmoved(0, 1)
  expect.equal(
    table.concat(trace, ' '),
    'move:10,20,3,-4 second:move press:2 second:press release:1 second:release wheel:0,1 second:wheel',
    'a raising handler does not stop the next'
  )
  expect.equal(#env.native.events.reported, 1, 'the raising handler is reported')
  mice:disable()
  table.clear(trace)
  lovr.mousemoved(0, 0, 1, 1)
  expect.equal(#trace, 0, 'mouse handlers end with their owner')
  env.session:close()
end)

test('simulate handlers replace the LÖVR simulator and give it back when they end', function()
  local fallbacks: { number } = {}
  lovr.simulate = function(dt: number)
    fallbacks[#fallbacks + 1] = dt
  end
  local env = start()
  local trace: { number } = {}
  lovr.simulate(0.5)
  expect.equal(table.concat(fallbacks, ' '), '0.5', 'with no handler, LÖVR simulates')
  local simulator = consumer(env, 'frame-simulate', function(context: plugin.Context, service: frameContract.Service)
    service:onSimulate(context, {
      run = function(dt: number)
        trace[#trace + 1] = dt
      end,
    })
  end)
  lovr.simulate(0.25)
  expect.equal(table.concat(trace, ' '), '0.25', 'the handler simulates')
  expect.equal(#fallbacks, 1, 'and LÖVR does not')
  simulator:disable()
  lovr.simulate(0.125)
  expect.equal(table.concat(fallbacks, ' '), '0.5 0.125', 'LÖVR simulates again once the handler ends')
  env.session:close()
end)

test('batch observers run first, and a consumed binding key or blockText blocks text until the next update', function()
  local env = start()
  local trace: { string } = {}
  local batches: { frameContract.Batch } = {}
  local events: { frameContract.HostKeyEvent } = {}
  local service: frameContract.Service?
  consumer(env, 'frame-batches', function(context: plugin.Context, frameService: frameContract.Service)
    service = frameService
    service:onBatch(context, {
      run = function(batch: frameContract.Batch)
        batches[#batches + 1] = batch
        trace[#trace + 1] = if batch.textBlocked then 'blocked' else 'batch'
      end,
    })
    service:onKey(context, {
      run = function(event: frameContract.HostKeyEvent): boolean
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
  consumer(env, 'frame-checks', function(context: plugin.Context, service: frameContract.Service)
    expect.raises(function()
      service:onUpdate(context, { run = function() end })
    end, 'frame onUpdate: phase is one of input, scene, pointing, overlay, not nil', 'a missing phase')
  end)
  env.session:close()
end)

test('quit runs its handlers, then stops the runtime', function()
  local env = start()
  local trace: { string } = {}
  consumer(env, 'frame-quit', function(context: plugin.Context, service: frameContract.Service)
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

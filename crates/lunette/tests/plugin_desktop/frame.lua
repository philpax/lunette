-- The frame and surfaces providers: phase order, key and text consumption,
-- owner-scoped cleanup, named surface offers, and registration checks.
local plugin = require '@lunette-plugin'
local frame = require '@lunette-plugins/frame'
local frameContract = require '@lunette-contracts/frame'
local surfacesContract = require '@lunette-contracts/surfaces'

local runtime = plugin.runtime()
local stopped = 0
frame.install {
  start = function() end,
  stop = function()
    stopped += 1
    runtime:close()
  end,
}
local frameProvider = runtime:use(frame.definition, {})
frameProvider:enable()
runtime:use(require '@lunette-plugins/surfaces', {}):enable()

local function rejects(call, expected)
  local ok, message = pcall(call)
  assert(not ok, 'expected a failure naming ' .. expected)
  assert(tostring(message):find(expected, 1, true), tostring(message))
end

-- A consumer whose initializer registers through the services it is given.
local consumers = {}
local function consumer(name, register)
  local instance = runtime:use(
    plugin.define {
      name = name,
      requires = { frame = frameContract.capability, surfaces = surfacesContract.capability },
      init = function(ctx)
        register(ctx, ctx:require(frameContract.capability), ctx:require(surfacesContract.capability))
      end,
    },
    {}
  )
  instance:enable()
  assert(instance:state() == 'active', tostring(instance:diagnostic()))
  consumers[#consumers + 1] = instance
  return instance
end

-- Update and draw run input, scene, pointing, then overlay; within a phase by
-- ascending order, then by registration.
local trace = {}
local function record(label)
  return function()
    trace[#trace + 1] = label
  end
end
local ordered = consumer('frame-order', function(ctx, service)
  service:onUpdate(ctx, { phase = 'overlay', run = record 'overlay' })
  service:onUpdate(ctx, { phase = 'scene', order = 1, run = record 'scene+1' })
  service:onUpdate(ctx, { phase = 'pointing', run = record 'pointing' })
  service:onUpdate(ctx, { phase = 'scene', run = record 'scene-first' })
  service:onUpdate(ctx, { phase = 'scene', run = record 'scene-second' })
  service:onUpdate(ctx, { phase = 'input', order = 5, run = record 'input' })
  service:onUpdate(ctx, { phase = 'scene', order = -1, run = record 'scene-1' })
  service:onDraw(ctx, { phase = 'overlay', run = record 'draw-overlay' })
  service:onDraw(ctx, { phase = 'scene', run = record 'draw-scene' })
  service:onDraw(ctx, { phase = 'input', run = record 'draw-input' })
  service:onDraw(ctx, { phase = 'pointing', run = record 'draw-pointing' })
end)
lovr.update(0.016)
assert(
  table.concat(trace, ' ') == 'input scene-1 scene-first scene-second scene+1 pointing overlay',
  table.concat(trace, ' ')
)
trace = {}
assert(lovr.draw(events.pass) == false)
assert(table.concat(trace, ' ') == 'draw-input draw-scene draw-pointing draw-overlay', table.concat(trace, ' '))

-- Handlers end with their owner, and a reloaded owner registers once again.
ordered:disable()
trace = {}
lovr.update(0.016)
lovr.draw(events.pass)
assert(#trace == 0, 'an unloaded owner leaves no frame handlers')
ordered:enable()
trace = {}
lovr.update(0.016)
assert(#trace == 7, 'a re-enabled owner registers its handlers once')
ordered:disable()

-- Bindings run before delivery. A handler that answers true consumes the
-- event; one that raises does not.
local keys, texts = {}, {}
local bindings = consumer('frame-keys', function(ctx, service)
  service:onKey(ctx, {
    phase = 'delivery',
    run = function(event)
      keys[#keys + 1] = 'deliver:' .. event.key
    end,
  })
  service:onKey(ctx, {
    order = 1,
    run = function(event)
      keys[#keys + 1] = 'bind:' .. event.key
      return event.key == 'f9'
    end,
  })
  service:onKey(ctx, {
    run = function(event)
      assert(event.scancode == 67 and event.isRepeat == true or event.key ~= 'f9', 'the key event carries LÖVR fields')
      assert(not pcall(function()
        event.key = 'changed'
      end), 'a key event is read-only, so a handler cannot change what later ones see')
      if event.key == 'f1' then
        error 'fixture binding failure'
      end
    end,
  })
  service:onText(ctx, {
    phase = 'delivery',
    run = function(event)
      texts[#texts + 1] = 'deliver:' .. event.text .. ':' .. event.code
    end,
  })
  service:onText(ctx, {
    phase = 'binding',
    run = function(event)
      texts[#texts + 1] = 'bind:' .. event.text
      return event.text == 'x'
    end,
  })
end)
lovr.keypressed('f9', 67, true)
assert(table.concat(keys, ' ') == 'bind:f9', 'a consumed key reaches no later handler: ' .. table.concat(keys, ' '))
keys = {}
lovr.keypressed('a', 4, false)
assert(table.concat(keys, ' ') == 'bind:a deliver:a', table.concat(keys, ' '))
keys = {}
local reports = #events.reported
lovr.keypressed('f1', 58, false)
assert(#events.reported == reports + 1 and events.reported[#events.reported].message:find('lovr.keypressed: ', 1, true))
assert(table.concat(keys, ' ') == 'bind:f1 deliver:f1', 'a raising binding consumes nothing')
lovr.textinput('x', 120)
lovr.textinput('y', 121)
assert(table.concat(texts, ' ') == 'bind:x bind:y deliver:y:121', table.concat(texts, ' '))
bindings:disable()
keys = {}
lovr.keypressed('a', 4, false)
assert(#keys == 0, 'key handlers end with their owner')

-- A handler disposed by an earlier one in the same dispatch is skipped.
local skipped = {}
consumer('frame-dispose', function(ctx, service)
  local later
  service:onUpdate(ctx, {
    phase = 'input',
    run = function()
      if later then
        later:dispose()
        later = nil
      end
    end,
  })
  later = service:onUpdate(ctx, {
    phase = 'scene',
    run = function()
      skipped[#skipped + 1] = true
    end,
  })
end)
lovr.update(0.016)
assert(#skipped == 0, 'a handler disposed earlier in the dispatch does not run')

-- Registrations are checked, and each error names the problem.
consumer('frame-checks', function(ctx, service, broker)
  rejects(function()
    service:onUpdate(ctx, { run = function() end })
  end, 'frame onUpdate: phase is one of input, scene, pointing, overlay, not nil')
  rejects(function()
    service:onDraw(ctx, { phase = 'background', run = function() end })
  end, 'frame onDraw: phase is one of input, scene, pointing, overlay, not background')
  rejects(function()
    service:onKey(ctx, { phase = 'scene', run = function() end })
  end, 'frame onKey: phase is one of binding, delivery, not scene')
  rejects(function()
    service:onUpdate(ctx, { phase = 'scene', oder = 1, run = function() end })
  end, 'frame onUpdate: unknown field oder')
  rejects(function()
    service:onUpdate(ctx, { phase = 'scene', order = math.huge, run = function() end })
  end, 'frame onUpdate: order is a finite number')
  rejects(function()
    service:onQuit(ctx, { phase = 'scene', run = function() end })
  end, 'frame onQuit: unknown field phase')
  rejects(function()
    service:onText(ctx, function() end)
  end, 'frame onText: a handler is a table of fields, not a function')
  rejects(function()
    broker:offer(ctx, { name = 'unlisted' })
  end, 'surfaces offer: list is a function, not a nil')
  rejects(function()
    broker:offer(ctx, { name = '', list = function() end })
  end, 'surfaces offer: name is a non-empty string')
end)

-- An offer name names one offer, until its effect or its owner ends.
local broker
local first = consumer('surfaces-first', function(ctx, _, service)
  broker = service
  service:offer(ctx, {
    name = 'fixture',
    list = function()
      return { { dead = false, raycast = function() end, label = 'first' } }
    end,
  })
end)
local offered
consumer('surfaces-second', function(ctx, _, service)
  rejects(function()
    service:offer(ctx, { name = 'fixture', list = function() end })
  end, 'surfaces offer: fixture is already offered')
  offered = service:offer(ctx, {
    name = 'second',
    list = function()
      return { { dead = false, raycast = function() end, label = 'second' } }
    end,
  })
end)
local listed = broker:all()
assert(#listed == 2 and listed[1].label == 'first' and listed[2].label == 'second', 'offers list in registration order')
offered:dispose()
assert(#broker:all() == 1)
first:disable()
assert(#broker:all() == 0, 'an offer ends with its owner')
consumer('surfaces-reuse', function(ctx, _, service)
  service:offer(ctx, {
    name = 'fixture',
    list = function()
      return {}
    end,
  })
end)

-- One frame activation receives the LÖVR callbacks at a time.
local other = plugin.runtime()
local second = other:use(frame.definition, {})
second:enable()
assert(second:state() == 'failed', 'a second frame activation fails to load')
assert(tostring(second:diagnostic()):find('another frame activation already receives the LÖVR callbacks', 1, true))
other:close()

-- While the frame provider is out, the callbacks do nothing and its
-- dependents unload; recovery restores them. The consumers above are retired
-- first, so recovery reloads only the one this case watches.
for _, instance in ipairs(consumers) do
  instance:dispose()
end
local ticks = 0
local ticking = consumer('frame-outage', function(ctx, service)
  service:onUpdate(ctx, {
    phase = 'scene',
    run = function()
      ticks += 1
    end,
  })
end)
frameProvider:disable()
assert(ticking:state() ~= 'active')
lovr.update(0.016)
assert(lovr.draw(events.pass) == false)
lovr.keypressed('a', 4, false)
assert(ticks == 0)
frameProvider:enable()
assert(ticking:state() == 'active')
lovr.update(0.016)
assert(ticks == 1)

assert(lovr.quit() == false)
assert(stopped == 1, 'quit stops the runtime after its handlers')

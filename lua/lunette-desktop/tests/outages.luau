-- Provider outages release dependent consumers and preserve unrelated panels, saved arrangements, and rule sources.
local testing = require '@testing'
local expect = testing.expect
local desktop = require '@lunette-desktop'
local panelsContract = require '@lunette-contracts/panels'
local rulesContract = require '@lunette-contracts/rules'
local surfacesContract = require '@lunette-contracts/surfaces'

local test = testing.suite()

local function start()
  local env = { session = testing.boot(desktop.entries()) }
  env.native, env.events = env.session.native, env.session.native.events
  env.instances = env.session.instances
  local panels = env.session:observe(panelsContract.capability)
  local rules = env.session:observe(rulesContract.capability)
  local surfaces = env.session:observe(surfacesContract.capability)
  setmetatable(env, {
    __index = function(_, key)
      return if key == 'panels'
        then panels.service
        elseif key == 'rules' then rules.service
        elseif key == 'surfaces' then surfaces.service
        else nil
    end,
  })
  return env
end

-- The shipped rule sources retain their configured precedence order across provider outages.
local function expectSources(env, context)
  local list = env.rules:sources()
  expect.equal(#list, 3, context .. ': the rule sources')
  expect.equal(list[1].precedence, 100, context .. ': the rule list')
  expect.equal(list[2].name, 'desktop.persist', context .. ': the saved arrangement')
  expect.equal(list[3].name, 'lunette.adoption', context .. ': adoption')
end

local function frame(env)
  env.session:update()
  expect.equal(env.session:draw(), false, 'draw does not veto')
end

local function expectAt(panel, x, y, z, context)
  local px, py, pz = panel.pose:getPosition()
  expect.near(px, x, 1e-5, context .. ', x')
  expect.near(py, y, 1e-5, context .. ', y')
  expect.near(pz, z, 1e-5, context .. ', z')
end

test('keyboard and error stream outages remove only what depends on them', function()
  local env = start()
  local native, events = env.native, env.events
  events.windows = { native.newWindow(10), native.newWindow(11, 'firefox') }
  for _, window in ipairs(events.windows) do
    native.emit('onWindowOpened', { window = window })
  end
  local initial = assert(env.panels:forSource(events.windows[1]))
  local firefox = assert(env.panels:forSource(events.windows[2]))
  expect.equal(firefox.width, 2, 'the configured rule sizes firefox')
  expect.near((firefox.pose:getPosition()), -1.4, 1e-5, 'the configured rule pose is outside the arc')
  expectSources(env, 'startup')

  for round = 1, 3 do
    local context = 'round ' .. round
    env.instances.keyboard:disable()
    expect.equal(env.panels:forSource(events.windows[1]), initial, context .. ': the panel stays')
    expect.equal(#env.surfaces:all(), 4, context .. ': the outage removes only the wrist and keyboard surfaces')
    frame(env)
    expectSources(env, context .. ', keyboard outage')
    env.instances.keyboard:enable()
    local all = env.surfaces:all()
    expect.equal(#all, 5, context .. ': recovery offers the wrist button')
    local pulses = 0
    all[5]:onPress(nil, nil, {
      vibrate = function()
        pulses += 1
        return true
      end,
    })
    expect.equal(pulses, 1, context .. ': the wrist button pulses the pointer that pressed it')
    expect.equal(#env.surfaces:all(), 6, context .. ': the press makes one keyboard')

    env.instances.errors:disable()
    expect.equal(native.subscriptionCount 'onError', 0, context .. ': the stream ends its subscription')
    expect.equal(env.panels:forSource(events.windows[1]), initial, context .. ': the panel stays')
    expectSources(env, context .. ', stream outage')
    frame(env)
    env.instances.errors:enable()
    expect.equal(native.subscriptionCount 'onError', 1, context .. ': the stream subscribes again')
  end
  env.session:close()
end)

test('a rules outage withdraws adopted panels, and recovery restores them where they were dropped', function()
  local env = start()
  local native, events = env.native, env.events
  local window = native.newWindow(10)
  events.windows = { window }
  native.emit('onWindowOpened', { window = window })
  local initial = assert(env.panels:forSource(window))
  initial:setPose(lovr.math.newMat4():translate(3, 2, -4))
  env.session:drop(initial)
  expect.equal(events.writes, 1, 'the drop saves the arrangement')
  local reads, writes = events.reads, events.writes
  for round = 1, 3 do
    local context = 'round ' .. round
    env.instances.rules:disable()
    expect.truthy(initial.dead, context .. ': the outage withdraws the adopted panel')
    expect.equal(native.subscriptionCount 'onWindowOpened', 0, context .. ': adoption unsubscribes')
    expect.equal(events.writes, writes, context .. ': persistence teardown never saves')
    for _, record in ipairs(events.subscriptions.onWindowOpened) do
      if not record.active then
        record.callback { window = window }
      end
    end
    expect.equal(env.panels:forSource(window), nil, context .. ': a retained native callback cannot place')
    frame(env)
    env.instances.rules:enable()
    expectSources(env, context)
    initial = assert(env.panels:forSource(window))
    expectAt(initial, 3, 2, -4, context .. ': the retained arrangement restores the panel')
    expect.equal(events.reads, reads, context .. ': the outage does not read the file again')
    expect.equal(native.subscriptionCount 'onWindowOpened', 1, context .. ': adoption subscribes again')
  end
  env.session:close()
end)

test('a surfaces outage stops pointing and decorations and leaves the panels drawing', function()
  local env = start()
  local native, events = env.native, env.events
  events.windows = { native.newWindow(1) }
  native.emit('onWindowOpened', { window = events.windows[1] })
  env.instances.surfaces:disable()
  expect.equal(env.instances['desktop/render']:state(), 'active', 'the outage keeps rendering')
  expect.truthy(env.instances['desktop/pointing']:state() ~= 'active', 'the outage stops pointing')
  expect.truthy(env.instances['desktop/decorations']:state() ~= 'active', 'the outage stops decorations')
  events.textures = 0
  frame(env)
  expect.equal(events.textures, 1, 'the panel draws during the outage')
  env.instances.surfaces:enable()
  expect.equal(#env.surfaces:all(), 3, 'recovery offers the panel, its bar, and the wrist button again')
  env.session:close()
end)

test('a bindings outage takes the desktop bindings away and leaves typing working', function()
  local env = start()
  local native, events = env.native, env.events
  events.windows = { native.newWindow(1) }
  native.emit('onWindowOpened', { window = events.windows[1] })
  env.session:update()
  events.trigger = true
  env.session:update()
  events.trigger = false
  env.session:update()
  env.instances.bindings:disable()
  expect.truthy(env.instances['desktop/bindings']:state() ~= 'active', 'the desktop bindings need the broker')
  expect.equal(env.instances['desktop/input']:state(), 'active', 'input does not need the broker')
  local before = #events.input
  lovr.keypressed('backspace', 0, false)
  expect.truthy(#events.input > before, 'a key reaches the focused window during the outage')
  env.instances.bindings:enable()
  expect.equal(env.instances['desktop/bindings']:state(), 'active', 'recovery restores the desktop bindings')
  env.session:close()
end)

test('the monitors consumer owns its mirrors and captures across its outages and replugs', function()
  local env = start()
  local native, events = env.native, env.events
  local monitors = env.instances['desktop/monitors']
  local function plug()
    local monitor = native.newMonitor 'fixture-output'
    events.monitors[monitor.id] = monitor
    native.emit('onMonitorAdded', { id = monitor.id, monitor = monitor })
    return monitor
  end
  local monitor = plug()
  expect.truthy(env.panels:forSource(monitor), 'the monitor is mirrored')
  monitors:disable()
  expect.equal(env.panels:forSource(monitor), nil, 'the consumer removes its mirrors as it unloads')
  expect.equal(events.unmirrored, 1, 'the consumer stops its capture as it unloads')
  monitors:enable()
  expect.truthy(env.panels:forSource(monitor), 'recovery mirrors the connected outputs again')
  expect.equal(events.mirrored, 2, 'recovery captures again')
  monitors:reload {}
  expect.equal(events.mirrored, 3, 'a reload captures again')
  expect.equal(events.unmirrored, 2, 'a reload releases the previous capture')
  monitor.dead = true
  env.session:update()
  monitor = plug()
  expect.truthy(env.panels:forSource(monitor), 'a reconnected output gets a new panel')

  -- The host reports quit-save failures even when the error stream is unavailable.
  env.instances.errors:disable()
  events.writeMode = 'refuse'
  expect.equal(env.session:quit(), false, 'quit does not veto')
  expect.equal(#events.reported, 1, 'the failed save is reported')
  expect.truthy(events.reported[1].message:find('arrangement was not saved', 1, true), events.reported[1].message)
  env.session:close()
end)

return test

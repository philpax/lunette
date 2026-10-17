local testing = require '@testing'
local expect = testing.expect
local lunette = require '@lunette'
local quad = require '@lunette-contracts/quad'
local fixture = require './support/fixture'
local test = testing.suite()

-- Reports a host failure, as the host does for a panel draw that raises, on each of `frames` frames.
local function failHost(env: fixture.Environment, frames: number): ()
  for _ = 1, frames do
    env.native.raise("ui: panel 'test' draw: deliberate failure", '')
    env:step()
  end
end

test('the panel shows while the host entry is disabled and hides when it recovers', function()
  fixture.run(nil, function(env: fixture.Environment): ()
    expect.equal(env:panel(), nil, 'hidden while the toolkit runs')
    env.composition:disable 'ui-host'
    env:step()
    expect.truthy(env:panel(), 'shown once the host is inactive')
    env:draw()
    local drawn = false
    for _, call in env.native.events.draw do
      if call[1] == 'text' and call[2] == 'The UI host is not running.' then
        drawn = true
      end
    end
    expect.truthy(drawn, 'default appearance says why it is disabled')
    env:click 'appearance'
    expect.equal(env.host.sets, 0, 'a disabled action does nothing')
    env.composition:enable 'ui-host'
    env:step()
    expect.equal(env:panel(), nil, 'hidden again once the host is active')
  end)
end)

test('persistent host errors show the panel, and default appearance switches by ray', function()
  fixture.run(nil, function(env: fixture.Environment): ()
    failHost(env, 2)
    expect.equal(env:panel(), nil, 'two frames of errors are below the threshold')
    failHost(env, 2)
    expect.truthy(env:panel(), 'errors on consecutive frames show the panel')
    env.native.raise("ui: panel 'test' draw: deliberate failure", '')
    env:click 'appearance'
    expect.equal(env.host.appearance, true, 'the click turns default appearance on')
    expect.equal(env.host.sets, 1, 'once')
    for _ = 1, 4 do
      env:step()
    end
    expect.equal(env:panel(), nil, 'quiet frames hide the panel')
  end)
end)

test('reload configuration and restart into safe mode are reachable by ray', function()
  fixture.run(nil, function(env: fixture.Environment): ()
    local original = lunette.reload
    local reloads = 0
    lunette.reload = function(): (boolean, string?)
      reloads += 1
      return true, nil
    end
    local ok, problem = pcall(function(): ()
      env.composition:disable 'ui-host'
      env:step()
      env:click 'reload'
    end)
    lunette.reload = original
    if not ok then
      error(problem, 0)
    end
    expect.equal(reloads, 1, 'reload runs once')
    env:click 'safe-mode'
    expect.equal(env.native.events.safeModeRestarts, 1, 'the safe mode restart is requested once')
  end)
end)

-- Offers a surface 0.3 m in front of the panel and twice its size, and answers how many presses reach it.
local function block(env: fixture.Environment): { presses: number }
  local panel = assert(env:panel())
  local counted = { presses = 0 }
  local blocker = {
    dead = false,
    pose = lovr.math.newMat4(panel.pose):translate(0, 0, 0.3),
    width = panel.width * 2,
    height = panel.height * 2,
    raycast = function(self: any, origin: vector, direction: vector): (number?, number?, number?)
      return quad.hit(
        { pose = self.pose, width = self.width, height = self.height, pixelWidth = 1, pixelHeight = 1 },
        origin,
        direction
      )
    end,
    onPointer = function(_self: any, event: any): ()
      if event.kind == 'press' then
        counted.presses += 1
      end
    end,
  }
  env.surfaces:offer(env.context, {
    name = 'blocker',
    list = function(): { any }
      return { blocker }
    end,
  })
  return counted
end

test('the panel wins picking over a nearer surface in front of it', function()
  fixture.run(nil, function(env: fixture.Environment): ()
    env.composition:disable 'ui-host'
    env:step()
    local counted = block(env)
    env:click 'safe-mode'
    expect.equal(counted.presses, 0, 'the nearer surface receives no press')
    expect.equal(env.native.events.safeModeRestarts, 1, 'the panel action runs')
  end)
end)

test('without its pick priority the nearer surface would take the click', function()
  fixture.run({ pickPriority = 0 }, function(env: fixture.Environment): ()
    env.composition:disable 'ui-host'
    env:step()
    local counted = block(env)
    env:click 'safe-mode'
    expect.equal(counted.presses, 1, 'the nearer surface receives the press')
    expect.equal(env.native.events.safeModeRestarts, 0, 'the panel action does not run')
  end)
end)

test('restore applies the last known good configuration by ray', function()
  fixture.run(nil, function(env: fixture.Environment): ()
    expect.equal(env.composition:lastGood(), nil, 'nothing is recorded at start')
    env:step(0.6)
    env:step(0.6)
    expect.truthy(env.composition:lastGood(), 'a healthy composition is recorded')
    env.composition:configure('settings', { value = 9 })
    expect.equal(assert(env.settings.current).value, 9, 'the changed configuration')
    env.composition:disable 'ui-host'
    env:step()
    env:click 'restore'
    expect.equal(assert(env.settings.current).value, 1, 'the recorded configuration is back')
    expect.equal(assert(env:entry 'ui-host').state, 'active', 'the host is enabled again')
    env:step()
    expect.equal(env:panel(), nil, 'the panel hides once the toolkit runs')
  end)
end)

test('saved settings are set aside by ray until the next start, and stay saved', function()
  fixture.run(nil, function(env: fixture.Environment): ()
    env.composition:configure('settings', { value = 9 })
    expect.equal(env.saved.overrides.settings.value, 9, 'the change is a saved setting')
    env.composition:disable 'ui-host'
    env:step()
    env:click 'without-saved'
    expect.equal(assert(env.settings.current).value, 1, 'the entry runs with its configuration again')
    expect.equal(env.saved.overrides.settings.value, 9, 'the saved setting stays for the Saved tab to forget')
    expect.equal(env.composition:savedSettings()[1].status, 'suspended', 'and is shown as set aside')
  end)
end)

return test

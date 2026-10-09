local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local panelsContract = require '@lunette-contracts/panels'

local test = testing.suite()

local function start(config)
  local env = { native = testing.native() }
  env.session = testing.start {
    { id = 'theme', definition = require('@lunette-plugins/theme').definition },
    { id = 'panels', definition = require('@lunette-plugins/panels').definition, config = config },
  }
  env.consumer = env.session:use(plugin.define {
    name = 'panels-test',
    requires = { panels = panelsContract.capability },
    init = function(context)
      env.panels = context:require(panelsContract.capability)
      env.owner = context
    end,
  })
  return env
end

local function another(env)
  return env.session:observe(panelsContract.capability).context
end

local function monitor(id)
  return {
    id = id,
    name = 'monitor ' .. id,
    dead = false,
    width = 1920,
    height = 1080,
    getTexture = function()
      return false
    end,
  }
end

test('a panel takes its size from its source, and is found by its source', function()
  local env = start()
  local source = env.native.newWindow(17)
  source.width, source.height = 800, 600
  local panel = env.panels:fromWindow(env.owner, source, { height = 1 })
  local monitorPanel = env.panels:fromMonitor(env.owner, monitor 'monitor-17', { height = 1 })
  expect.equal(panel.kind, 'window', 'the kind')
  expect.equal(panel.source, source, 'the source')
  expect.near(panel.width, 4 / 3, 1e-9, 'the width')
  expect.equal(panel.height, 1, 'the height')
  expect.equal(monitorPanel.kind, 'monitor', 'the monitor kind')
  expect.falsy(monitorPanel.claim, 'a monitor panel claims no layer')
  expect.equal(#env.panels:all(), 2, 'the panels')
  expect.equal(env.panels:forSource { id = 17 }, panel, 'the panel found by window id')
  expect.equal(env.panels:forSource { id = 'monitor-17' }, monitorPanel, 'the panel found by monitor id')
  expect.falsy(panel.highlighted, 'the highlight of a new panel')
  panel:setHighlighted(true)
  expect.truthy(panel.highlighted, 'the highlight once set')
  env.session:close()
end)

test('monitor panel sizing follows oriented geometry and preserves the selected size axis', function()
  local env = start()
  local source = monitor 'portrait'
  source.logicalWidth, source.logicalHeight = 1080, 1920
  local widthPanel = env.panels:fromMonitor(env.owner, source, { width = 1 })
  expect.near(widthPanel.height, 1920 / 1080, 1e-9, 'portrait aspect does not use the landscape mode')
  source.logicalWidth, source.logicalHeight = 1920, 1080
  env.panels:update()
  expect.equal(widthPanel.width, 1)
  expect.near(widthPanel.height, 1080 / 1920, 1e-9, 'rotation refreshes the panel aspect')
  widthPanel:setSize(nil, 0.5)
  source.logicalWidth, source.logicalHeight = 1080, 1920
  env.panels:update()
  expect.equal(widthPanel.height, 0.5)
  expect.near(widthPanel.width, 0.5 * 1080 / 1920, 1e-9, 'height remains the selected size axis')
  widthPanel:setSize(1, 0.7)
  source.logicalWidth, source.logicalHeight = 1920, 1080
  env.panels:update()
  expect.equal(widthPanel.width, 1)
  expect.equal(widthPanel.height, 0.7, 'explicit dimensions do not change with the source')
  env.session:close()
end)

test('a panel with unavailable source dimensions acquires the source aspect on update', function()
  local env = start()
  local source = monitor 'pending-mode'
  source.width, source.height = 0, 0
  local panel = env.panels:fromMonitor(env.owner, source, { width = 1 })
  source.width, source.height = 1080, 1920
  env.panels:update()
  expect.equal(panel.width, 1)
  expect.near(panel.height, 1920 / 1080, 1e-9)
  env.session:close()
end)

test('an opaque window draws through a shader made once per activation and released with it', function()
  local env = start()
  local source = env.native.newWindow(17)
  source.opaque = true
  source.getTexture = function()
    return { name = 'window-texture' }
  end
  env.panels:fromWindow(env.owner, source, { height = 1 })
  local pass = env.native.events.pass
  env.panels:draw(pass)
  local shaders = env.native.events.render.shaderAcquisitions
  expect.equal(#shaders, 1, 'the shaders after the first draw')
  env.panels:draw(pass)
  expect.equal(#shaders, 1, 'the shaders after the second draw')
  env.session:close()
  expect.truthy(shaders[1].released, 'the shader is released')
end)

test('only a plugin requiring panels creates one, and only its creator destroys it', function()
  local env = start()
  local source = env.native.newWindow(17)
  local raised
  env.session:use(plugin.define {
    name = 'panels-test-without',
    init = function(context)
      raised = not pcall(function()
        env.panels:fromWindow(context, source, { height = 1 })
      end)
    end,
  })
  expect.truthy(raised, 'creating a panel without requiring panels raised')
  local panel = env.panels:fromWindow(env.owner, source, { height = 1 })
  local stranger = another(env)
  expect.raises(function()
    panel:destroy(stranger)
  end, nil, 'a stranger destroying the panel')
  expect.falsy(panel.dead, 'the panel a stranger tried to destroy')
  expect.truthy(panel:destroy(env.owner), 'the creator destroys it')
  expect.falsy(panel:destroy(env.owner), 'destroying it again')
  expect.equal(#env.panels:all(), 0, 'the panels')
  env.session:close()
end)

test('a panel over a dead source is removed on update, and not taken for its replacement', function()
  local env = start()
  local replugged = monitor 'monitor-18'
  local panel = env.panels:fromMonitor(env.owner, replugged, { height = 1 })
  replugged.dead = true
  expect.equal(env.panels:forSource(monitor 'monitor-18'), nil, 'the replacement source')
  env.panels:update()
  expect.truthy(panel.dead, 'the panel after its source died')
  expect.equal(#env.panels:all(), 0, 'the panels')
  env.session:close()
end)

test("a panel ends with its owner, and the provider's service is stale once it is disabled", function()
  local env = start()
  local source = env.native.newWindow(17)
  local panel = env.panels:fromWindow(env.owner, source, { height = 1 })
  local claims = #env.native.events.claims
  env.consumer:disable()
  expect.truthy(panel.dead, 'the panel after its owner ended')
  expect.falsy(panel:destroy(), 'destroying the ended panel')
  local stale = env.panels
  env.session.instances.panels:disable()
  source.width, source.height = 1600, 1200
  expect.raises(function()
    stale:update()
  end, nil, 'updating through the stale service')
  expect.equal(#env.native.events.claims, claims, 'the claims after the stale update')
  env.session:close()
end)

test('a destroyed panel, or one whose source died, retains nothing', function()
  local env = start()
  local weak = setmetatable({}, { __mode = 'v' })
  for round = 1, 8 do
    do
      local source = env.native.newWindow(99)
      weak[round] = source
      local panel = env.panels:fromWindow(env.owner, source)
      if round % 2 == 0 then
        source.dead = true
        panel:update()
        expect.truthy(panel.dead, 'the panel of a dead source')
      else
        expect.truthy(panel:destroy(env.owner), 'the destroyed panel')
      end
      expect.equal(env.panels:forSource(source), nil, 'the ended panel found by its source')
    end
    testing.collect()
    testing.collect()
    expect.equal(weak[round], nil, 'the source of ended panel ' .. round)
  end
  env.session:close()
end)

test('a claim that fails as a panel is created registers nothing, and a retry succeeds', function()
  local env = start { rendering = 'layer' }
  local native = require '@lunette'
  local existing = env.native.newWindow(301)
  local kept = env.panels:fromWindow(env.owner, existing)
  local source = env.native.newWindow(302)
  local claim = native.claimLayer
  native.claimLayer = function()
    native.claimLayer = claim
    error 'fixture: initial claim failure'
  end
  expect.raises(function()
    env.panels:fromWindow(env.owner, source)
  end, 'fixture: initial claim failure', 'the failing creation')
  expect.equal(#env.panels:all(), 1, 'the panels after the failure')
  expect.equal(env.panels:forSource(existing), kept, 'the existing panel')
  expect.equal(env.panels:forSource(source), nil, 'the source of the failed panel')
  expect.equal(#env.native.events.claims, 1, 'the claims after the failure')
  local retried = env.panels:fromWindow(env.owner, source)
  expect.equal(env.panels:forSource(source), retried, 'the retried panel')
  expect.equal(#env.native.events.claims, 2, 'the claims after the retry')
  env.consumer:disable()
  expect.truthy(kept.dead and retried.dead, 'the panels after the owner ended')
  env.session:close()
end)

return test

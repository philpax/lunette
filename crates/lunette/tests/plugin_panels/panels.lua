return function()
  local plugin = require '@lunette-plugin'
  local contracts = require '@lunette-contracts/panels'
  local definition = require '@lunette-plugins/panels'

  local function identity(value)
    return value
  end

  local source = {
    id = 17,
    dead = false,
    width = 800,
    height = 600,
    title = 'Test window',
    opaque = false,
    sink = nil,
  }
  function source:getTexture()
    return false
  end

  local monitor = {
    id = 'monitor-17',
    name = 'Test monitor',
    dead = false,
    width = 1920,
    height = 1080,
    sink = nil,
  }
  function monitor:getTexture()
    return false
  end

  local runtime = plugin.runtime()
  local provider = runtime:use(definition, {})
  provider:enable()

  local service
  local owner
  local panel
  local monitorPanel
  local consumer = plugin.define(identity, { panels = contracts.capability }, {}, function(context)
    service = context:require(contracts.capability)
    owner = context
  end)

  local consumerInstance = runtime:use(consumer, {})
  consumerInstance:enable()

  panel = service:fromWindow(owner, source, { height = 1, chrome = false })
  monitorPanel = service:fromMonitor(owner, monitor, { height = 1, chrome = false })
  assert(panel.kind == 'window')
  assert(panel.source == source)
  assert(panel.width == 4 / 3)
  assert(panel.height == 1)
  assert(panel.highlighted == false)
  panel:setHighlighted(true)
  assert(panel.highlighted == true)
  assert(#service:all() == 2)
  assert(service:forSource { id = 17 } == panel)
  assert(service:forSource { id = 'monitor-17' } == monitorPanel)
  assert(panel:sourceSize() == 800)

  local opaqueOwner
  local opaqueConsumer = plugin.define(identity, { panels = contracts.capability }, {}, function(context)
    opaqueOwner = context
  end)
  local opaqueInstance = runtime:use(opaqueConsumer, {})
  opaqueInstance:enable()
  source.opaque = true
  source.getTexture = function()
    return { name = 'window-texture' }
  end
  local pass = {
    setBlendMode = function() end,
    setShader = function() end,
    setMaterial = function() end,
    plane = function() end,
  }
  service:draw(pass)
  assert(shaderCreated == 1)
  assert(service:opaqueShader(opaqueOwner) ~= nil)
  assert(shaderCreated == 1)

  local fresh = plugin.define(identity, {}, {}, function(context)
    local ok = pcall(function()
      service:opaqueShader(context)
    end)
    assert(not ok)
    assert(shaderCreated == 1)
  end)
  local freshInstance = runtime:use(fresh, {})
  freshInstance:enable()

  local stale = opaqueOwner
  opaqueInstance:disable()
  local staleOk = pcall(function()
    service:opaqueShader(stale)
  end)
  assert(not staleOk)
  assert(shaderCreated == 1)

  local rejected = plugin.define(identity, {}, {}, function(context)
    local ok = pcall(function()
      service:fromWindow(context, source, { height = 1, chrome = false })
    end)
    assert(not ok)
  end)
  local rejectedInstance = runtime:use(rejected, {})
  rejectedInstance:enable()

  assert(panel:destroy())
  assert(not panel:destroy())
  assert(panel.dead)
  panel:setHighlighted(false)
  assert(panel.highlighted == true)
  assert(not panel:sink())
  assert(#service:all() == 1)
  assert(not monitorPanel.claim)
  assert(not monitorPanel.granted)

  local beforeReplacement = claimCount
  source.width = 1600
  source.height = 1200
  consumerInstance:disable()
  freshInstance:disable()
  rejectedInstance:disable()
  provider:disable()
  local updateOk = pcall(function()
    service:update()
  end)
  assert(not updateOk)
  assert(claimCount == beforeReplacement)

  runtime:close()
  assert(shaderReleased == 1)
  assert(panel.dead)
  assert(monitorPanel.dead)
end

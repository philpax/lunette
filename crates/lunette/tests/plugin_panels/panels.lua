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

  -- Only the creating owner destroys a panel.
  local stranger
  local strangerInstance = runtime:use(
    plugin.define(identity, { panels = contracts.capability }, {}, function(context)
      stranger = context
    end),
    {}
  )
  strangerInstance:enable()
  assert(not pcall(function()
    panel:destroy(stranger)
  end))
  assert(not panel.dead)

  -- Removal and arrival listeners are owner-scoped and hear every cause.
  local added, removed, reported = {}, {}, {}
  require('@lunette').reportError = function(context, message)
    reported[#reported + 1] = context .. ': ' .. message
  end
  service:onAdded(stranger, function(created)
    added[#added + 1] = created
  end)
  service:onAdded(stranger, function()
    error 'arrival listener failed'
  end)
  local removal = service:onRemoved(stranger, panel, function(target)
    removed[#removed + 1] = target
  end)
  service:onRemoved(stranger, nil, function()
    error 'removal listener failed'
  end)

  assert(panel:destroy(owner))
  assert(not panel:destroy(owner))
  assert(panel.dead)
  assert(#removed == 1 and removed[1] == panel, 'the removal listener hears its panel')
  assert(#reported == 1 and reported[1]:find('removal listener failed', 1, true), 'a raising listener is reported')
  removal:dispose()

  local replugged = { id = 'monitor-18', name = 'Replugged', dead = false, width = 1920, height = 1080 }
  function replugged:getTexture()
    return false
  end
  local first = service:fromMonitor(owner, replugged, { height = 1, chrome = false })
  assert(#added == 1 and added[1] == first, 'the arrival listener hears a new panel')
  assert(#reported == 2 and reported[2]:find('arrival listener failed', 1, true))
  replugged.dead = true
  local again = { id = 'monitor-18', name = 'Replugged', dead = false, width = 1920, height = 1080 }
  assert(service:forSource(again) == nil, 'a panel over a dead source is not taken for its replacement')
  service:update()
  assert(first.dead and #removed == 1, 'a source that dies removes its panel')
  strangerInstance:disable()

  assert(not pcall(function()
    service.STYLE.borderThickness = 1
  end), 'the style is frozen')
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

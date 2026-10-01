-- Substitute providers of the panels, placement, and errors contracts,
-- composed with the built-in providers and desktop consumers that use them.
-- Each substitute is written against the contract alone.
local plugin = require '@lunette-plugin'
local frame = require '@lunette-plugins/frame'
local panelsContract = require '@lunette-contracts/panels'
local rulesContract = require '@lunette-contracts/rules'
local tagsContract = require '@lunette-contracts/tags'
local adoptionContract = require '@lunette-contracts/adoption'
local placementContract = require '@lunette-contracts/placement'
local errorsContract = require '@lunette-contracts/errors'

local function consumer(runtime, required, initialize)
  local instance = runtime:use(
    plugin.define {
      name = 'substitutes-1',
      requires = required,
      init = initialize,
    },
    {}
  )
  instance:enable()
  return instance
end

-- A panels provider that keeps panels in a list and announces removal to
-- owner-scoped listeners, as the contract requires.
local substitutePanels = plugin.define {
  name = 'substitutePanels',
  provides = { panels = panelsContract.capability },
  init = function(context, _, publish)
    local live, removed = {}, {}
    local function retire(panel)
      if panel.dead then
        return false
      end
      panel.dead = true
      table.remove(live, table.find(live, panel))
      for _, listener in ipairs(table.clone(removed)) do
        if listener.active and (not listener.panel or listener.panel == panel) then
          listener.callback(panel)
        end
      end
      return true
    end
    local function listen(owner, panel, callback)
      return context:acquire(owner, function()
        local listener = { panel = panel, callback = callback, active = true }
        removed[#removed + 1] = listener
        return function()
          listener.active = false
          table.remove(removed, table.find(removed, listener))
        end
      end)
    end
    local function make(owner, kind, source, options)
      local panel = {
        kind = kind,
        source = source,
        dead = false,
        pose = (options and options.pose) or lovr.math.newMat4(),
        width = (options and options.width) or 1,
        height = 1,
        owner = owner,
      }
      function panel:destroy(caller)
        assert(caller == self.owner, 'substitute: only the owner destroys a panel')
        return retire(self)
      end
      function panel:setPose(pose)
        self.pose = pose
      end
      function panel:setSize(width)
        self.width = width or self.width
      end
      function panel.raycast()
        return nil
      end
      context:acquire(owner, function()
        live[#live + 1] = panel
        return function()
          retire(panel)
        end
      end)
      return panel
    end
    local service = {
      STYLE = {},
      DEFAULT_PRIORITY = 10,
      DEFAULT_HEIGHT = 1,
      DEFAULT_ASPECT = 1,
      OPAQUE_FRAGMENT = '',
      rayQuadHit = function()
        return nil
      end,
      fromWindow = function(_, owner, window, options)
        return make(owner, 'window', window, options)
      end,
      fromMonitor = function(_, owner, monitor, options)
        return make(owner, 'monitor', monitor, options)
      end,
      all = function()
        return table.clone(live)
      end,
      forSource = function(_, source)
        for _, panel in ipairs(live) do
          if panel.source.id == source.id then
            return panel
          end
        end
        return nil
      end,
      update = function()
        for _, panel in ipairs(table.clone(live)) do
          if panel.source.dead then
            retire(panel)
          end
        end
      end,
      draw = function() end,
      opaqueShader = function()
        return nil
      end,
      onDropped = function(_, owner)
        return context:acquire(owner, function()
          return function() end
        end)
      end,
      emitDropped = function() end,
      onAdded = function(_, owner)
        return context:acquire(owner, function()
          return function() end
        end)
      end,
      onRemoved = function(_, owner, listener)
        return listen(owner, listener.panel, listener.run)
      end,
    }
    publish:provide(panelsContract.capability, service)
  end,
}

-- Placement's cleanup needs only the panels contract's removal announcement.
do
  local runtime = plugin.runtime()
  runtime:use(substitutePanels, {}):enable()
  runtime:use(require('@lunette-plugins/tags').definition, {}):enable()
  runtime:use(require('@lunette-plugins/rules').definition, {}):enable()
  runtime:use(require('@lunette-plugins/placement').definition, {}):enable()
  local owner, panels, tags, placement
  consumer(
    runtime,
    { panels = panelsContract.capability, tags = tagsContract.capability, placement = placementContract.capability },
    function(context)
      owner = context
      panels = context:require(panelsContract.capability)
      tags = context:require(tagsContract.capability)
      placement = context:require(placementContract.capability)
    end
  )
  local held = tags:new(owner, 'held')
  local window = newWindow(40)
  local panel = placement:place(owner, { window = window, defaults = { tags = { held, 'made-for-placement' } } })
  assert(held:has(panel) and tags:find 'made-for-placement', 'the placement holds its tags')
  window.dead = true
  panels:update()
  assert(panel.dead, 'the substitute removed the panel')
  assert(not held:has(panel) and #held.members == 0, 'the removal ended the placement membership')
  assert(not tags:find 'made-for-placement', 'the removal ended the tag the placement made')
  runtime:close()
end

-- Adoption works through a substitute placement provider, and an adoption
-- ends with its panel.
do
  local runtime = plugin.runtime()
  runtime:use(require('@lunette-plugins/panels').definition, {}):enable()
  runtime:use(require('@lunette-plugins/rules').definition, {}):enable()
  local placements = {}
  local substitutePlacement = plugin.define {
    name = 'substitutePlacement',
    requires = { panels = panelsContract.capability },
    provides = { placement = placementContract.capability },
    init = function(context, _, publish)
      local panels = context:require(panelsContract.capability)
      local service = {
        place = function(_, owner, request)
          local panel
          local effect = context:acquire(owner, function()
            panel = panels:fromWindow(context, request.window)
            placements[#placements + 1] = panel
            return function()
              table.remove(placements, table.find(placements, panel))
              panel:destroy(context)
            end
          end)
          return panel, {}, effect
        end,
        placed = function()
          return {}
        end,
        onPlaced = function(_, owner)
          return context:acquire(owner, function()
            return function() end
          end)
        end,
      }
      publish:provide(placementContract.capability, service)
    end,
  }
  runtime:use(substitutePlacement, {}):enable()
  runtime:use(require('@lunette-plugins/adoption').definition, {}):enable()
  local window = newWindow(41)
  events.windows = { window }
  local adopted = {}
  local caller = consumer(runtime, { adoption = adoptionContract.capability }, function(context)
    local adoption = context:require(adoptionContract.capability)
    adoption:install(context)
    adoption:start(context, {
      onPlaced = function(panel)
        adopted[#adopted + 1] = panel
      end,
    })
  end)
  assert(#adopted == 1 and #placements == 1, 'adoption placed through the substitute')
  window.dead = true
  events.windows = {}
  caller:disable()
  assert(adopted[1].dead and #placements == 0, 'the caller unloading ended its placement')
  caller:enable()
  local reopened = newWindow(42)
  events.windows = { reopened }
  emit('onWindowOpened', { window = reopened })
  assert(#placements == 1)
  local panel = placements[1]
  reopened.dead = true
  runtime:close()
  assert(panel.dead and #placements == 0)
end

-- The desktop's error panel presents what a substitute stream delivers.
do
  local runtime = plugin.runtime()
  frame.install {
    start = function() end,
    stop = function()
      runtime:close()
    end,
  }
  runtime:use(frame.definition, {}):enable()
  local subscribers = {}
  local substituteStream = plugin.define {
    name = 'substituteStream',
    provides = { errors = errorsContract.capability },
    init = function(context, _, publish)
      publish:provide(errorsContract.capability, {
        subscribe = function(_, owner, subscriber)
          return context:acquire(owner, function()
            subscribers[#subscribers + 1] = subscriber
            return function()
              table.remove(subscribers, table.find(subscribers, subscriber))
            end
          end)
        end,
        recent = function()
          return {}
        end,
        clear = function()
          for _, subscriber in ipairs(subscribers) do
            subscriber.cleared()
          end
        end,
      })
    end,
  }
  runtime:use(substituteStream, {}):enable()
  runtime:use(require '@lunette-desktop/errors', {}):enable()
  local function texts()
    local found = {}
    for _, call in ipairs(events.draw) do
      if call[1] == 'text' then
        found[#found + 1] = tostring(call[2])
      end
    end
    return table.concat(found, ' ')
  end
  events.draw = {}
  assert(lovr.draw(events.pass) == false)
  assert(texts() == '', 'nothing is presented before a report')
  assert(#subscribers == 1, 'the error panel subscribes')
  subscribers[1].run {
    message = 'substitute failure',
    traceback = '',
    suppressed = 0,
    text = 'substitute failure',
    sequence = 1,
    time = 0,
  }
  events.draw = {}
  assert(lovr.draw(events.pass) == false)
  assert(texts():find('substitute failure', 1, true), 'the error panel presents the substitute stream')
  subscribers[1].cleared()
  events.draw = {}
  assert(lovr.draw(events.pass) == false)
  assert(texts() == '', 'a cleared stream is presented as nothing')
  assert(lovr.quit() == false)
end

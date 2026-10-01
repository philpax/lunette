-- Substitute providers of the panels, rules, and error-display contracts,
-- composed with the built-in providers and desktop consumers that use them.
-- Each substitute is written against the contract alone.
local plugin = require '@lunette-plugin'
local frame = require '@lunette-plugins/frame'
local panelsContract = require '@lunette-contracts/panels'
local rulesContract = require '@lunette-contracts/rules'
local tagsContract = require '@lunette-contracts/tags'
local adoptionContract = require '@lunette-contracts/adoption'
local displayContract = require '@lunette-contracts/error-display'

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

-- Rules' placement cleanup needs only the contract's removal announcement.
do
  local runtime = plugin.runtime()
  runtime:use(substitutePanels, {}):enable()
  runtime:use(require '@lunette-plugins/tags', {}):enable()
  runtime:use(require '@lunette-plugins/rules', {}):enable()
  local owner, panels, tags, rules
  consumer(
    runtime,
    { panels = panelsContract.capability, tags = tagsContract.capability, rules = rulesContract.capability },
    function(context)
      owner = context
      panels = context:require(panelsContract.capability)
      tags = context:require(tagsContract.capability)
      rules = context:require(rulesContract.capability)
    end
  )
  local held = tags:new(owner, 'held')
  local window = newWindow(40)
  local panel = rules:place(owner, window, { tags = { held, 'made-for-placement' } })
  assert(held:has(panel) and tags:find 'made-for-placement', 'the placement holds its tags')
  window.dead = true
  panels:update()
  assert(panel.dead, 'the substitute removed the panel')
  assert(not held:has(panel) and #held.members == 0, 'the removal ended the placement membership')
  assert(not tags:find 'made-for-placement', 'the removal ended the tag the placement made')
  runtime:close()
end

-- Adoption works through a substitute rules provider, and an adoption ends
-- with its panel.
do
  local runtime = plugin.runtime()
  runtime:use(require '@lunette-plugins/panels', {}):enable()
  local placements = {}
  local substituteRules = plugin.define {
    name = 'substituteRules',
    requires = { panels = panelsContract.capability },
    provides = { rules = rulesContract.capability },
    init = function(context, _, publish)
      local panels = context:require(panelsContract.capability)
      local sources = {}
      local service = {
        DEFAULT_PRECEDENCE = 100,
        DEFAULT_SOURCE = 'substitute',
        PANEL_PROPERTIES = {},
        report = function() end,
        addSource = function(_, owner, registration)
          return context:acquire(owner, function()
            local source =
              { name = registration.name, precedence = registration.precedence, resolve = registration.resolve }
            sources[#sources + 1] = source
            return function()
              table.remove(sources, table.find(sources, source))
            end
          end)
        end,
        sources = function()
          return table.clone(sources)
        end,
        fromList = function()
          return function()
            return nil
          end
        end,
        setRules = function(self, owner)
          return self:addSource(owner, {
            name = 'substitute',
            precedence = 100,
            resolve = function()
              return nil
            end,
          })
        end,
        matches = function()
          return true
        end,
        resolve = function()
          return {}
        end,
        place = function(_, owner, window)
          local panel
          local effect = context:acquire(owner, function()
            panel = panels:fromWindow(context, window)
            placements[#placements + 1] = panel
            return function()
              table.remove(placements, table.find(placements, panel))
              panel:destroy(context)
            end
          end)
          return panel, {}, effect
        end,
      }
      publish:provide(rulesContract.capability, service)
    end,
  }
  runtime:use(substituteRules, {}):enable()
  runtime:use(require '@lunette-plugins/adoption', {}):enable()
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

-- The desktop's error consumer draws through a substitute display.
do
  local runtime = plugin.runtime()
  frame.install {
    start = function() end,
    stop = function()
      runtime:close()
    end,
  }
  runtime:use(frame.definition, {}):enable()
  local drawn = 0
  local substituteDisplay = plugin.define {
    name = 'substituteDisplay',
    provides = { display = displayContract.capability },
    init = function(_, _, publish)
      local function nothing() end
      publish:provide(displayContract.capability, {
        WINDOW = 1,
        MAX_KEYS = 1,
        X = 0,
        Y = 0,
        Z = 0,
        WIDTH = 1,
        TEXT_HEIGHT = 1,
        COLUMNS = 1,
        LINES = 1,
        BACKGROUND = { 0, 0, 0, 1 },
        newLimiter = nothing,
        keyFor = function()
          return ''
        end,
        handle = function()
          return true
        end,
        show = nothing,
        clear = nothing,
        current = nothing,
        count = function()
          return 0
        end,
        lines = function()
          return {}
        end,
        draw = function()
          drawn += 1
          return true
        end,
      })
    end,
  }
  runtime:use(substituteDisplay, {}):enable()
  runtime:use(require 'desktop/errors', {}):enable()
  assert(lovr.draw(events.pass) == false)
  assert(drawn == 1, 'the error consumer drew through the substitute')
  assert(lovr.quit() == false)
end

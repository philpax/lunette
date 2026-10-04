-- Placement teardown depends on the panels contract's removal announcement.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local panelsContract = require '@lunette-contracts/panels'
local tagsContract = require '@lunette-contracts/tags'
local placementContract = require '@lunette-contracts/placement'

local test = testing.suite()

-- The substitute announces removals to live owner-scoped listeners.
local substitutePanels = plugin.define {
  name = 'substitute-panels',
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
          listener.run(panel)
        end
      end
      return true
    end
    publish:provide(panelsContract.capability, {
      fromWindow = function(_, owner, window)
        local panel = { kind = 'window', source = window, dead = false, owner = owner }
        function panel:destroy(caller)
          assert(caller == self.owner, 'substitute: only the owner destroys a panel')
          return retire(self)
        end
        context:acquire(owner, function()
          live[#live + 1] = panel
          return function()
            retire(panel)
          end
        end)
        return panel
      end,
      onRemoved = function(_, owner, listener)
        return context:acquire(owner, function()
          local entry = { panel = listener.panel, run = listener.run, active = true }
          removed[#removed + 1] = entry
          return function()
            entry.active = false
            table.remove(removed, table.find(removed, entry))
          end
        end)
      end,
      update = function()
        for _, panel in ipairs(table.clone(live)) do
          if panel.source.dead then
            retire(panel)
          end
        end
      end,
    })
  end,
}

test("a removal the substitute announces ends the placement's memberships and the tag it made", function()
  local native = testing.native()
  local session = testing.start {
    { id = 'panels', definition = substitutePanels },
    'tags',
    'rules',
    'placement',
  }
  local env = {}
  session:use(plugin.define {
    name = 'substitute-panels-test',
    requires = {
      panels = panelsContract.capability,
      tags = tagsContract.capability,
      placement = placementContract.capability,
    },
    init = function(context)
      env.owner = context
      env.panels = context:require(panelsContract.capability)
      env.tags = context:require(tagsContract.capability)
      env.placement = context:require(placementContract.capability)
    end,
  })
  local held = env.tags:new(env.owner, 'held')
  local window = native.newWindow(40)
  local panel =
    env.placement:place(env.owner, { window = window, defaults = { tags = { held, 'made-for-placement' } } })
  expect.truthy(held:has(panel), 'the placement holds a membership of the tag given')
  expect.truthy(env.tags:find 'made-for-placement', 'the placement made the tag it named')
  window.dead = true
  env.panels:update()
  expect.truthy(panel.dead, 'the substitute removed the panel')
  expect.falsy(held:has(panel), 'the removal ended the membership')
  expect.equal(#held.members, 0, 'the members of the held tag')
  expect.equal(env.tags:find 'made-for-placement', nil, 'the removal ended the tag the placement made')
  session:close()
end)

return test

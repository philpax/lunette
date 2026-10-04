local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adoptionContract = require '@lunette-contracts/adoption'
local panelsContract = require '@lunette-contracts/panels'
local placementContract = require '@lunette-contracts/placement'

local test = testing.suite()

local function substitutePlacement(placements)
  return plugin.define {
    name = 'substitute-placement',
    requires = { panels = panelsContract.capability },
    provides = { placement = placementContract.capability },
    init = function(context, _, publish)
      local panels = context:require(panelsContract.capability)
      publish:provide(placementContract.capability, {
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
      })
    end,
  }
end

test('adoption places through a substitute, and an adoption ends with its caller', function()
  local native = testing.native()
  local placements = {}
  local session = testing.start {
    'panels',
    'rules',
    { id = 'placement', definition = substitutePlacement(placements) },
    'adoption',
  }
  local window = native.newWindow(41)
  native.events.windows = { window }
  local adopted = {}
  local caller = session:use(plugin.define {
    name = 'substitute-placement-test',
    requires = { adoption = adoptionContract.capability },
    init = function(context)
      local adoption = context:require(adoptionContract.capability)
      adoption:install(context)
      adoption:start(context, {
        onPlaced = function(panel)
          adopted[#adopted + 1] = panel
        end,
      })
    end,
  })
  expect.equal(#adopted, 1, 'the adopted panels')
  expect.equal(#placements, 1, 'the placements made through the substitute')
  expect.equal(adopted[1], placements[1], 'the adopted panel is the substitute placement')

  window.dead = true
  native.events.windows = {}
  caller:disable()
  expect.truthy(adopted[1].dead, "the panel after the caller's adoption ends")
  expect.equal(#placements, 0, 'the placements after the caller unloads')

  caller:enable()
  local reopened = native.newWindow(42)
  native.events.windows = { reopened }
  native.emit('onWindowOpened', { window = reopened })
  expect.equal(#placements, 1, 'the reopened window is placed again')
  local panel = placements[1]
  expect.equal(panel.source, reopened, 'the window placed')
  session:close()
  expect.truthy(panel.dead, 'the panel after the session closes')
  expect.equal(#placements, 0, 'the placements after the session closes')
end)

return test

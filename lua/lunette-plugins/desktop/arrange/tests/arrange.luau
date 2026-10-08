local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local layoutsContract = require '@lunette-contracts/layouts'
local placementContract = require '@lunette-contracts/placement'

local test = testing.suite()

local MISSING = 'desktop/arrange: later is not a registered layout; the registered layouts are arc'

test('a layout that is not registered is logged once, and the consumer arranges once it registers', function()
  local session = testing.boot {
    'frame',
    'drops',
    'theme',
    'panels',
    'tags',
    'rules',
    'placement',
    'layouts',
    'layout/arc',
    { id = 'desktop/arrange', factory = require '@lunette-plugins/desktop/arrange', config = { layout = 'later' } },
  }
  local native = session.native
  local probe = {}
  session:use(plugin.define {
    name = 'arrange-test',
    requires = { layouts = layoutsContract.capability, placement = placementContract.capability },
    init = function(context)
      probe.owner = context
      probe.layouts = context:require(layoutsContract.capability)
      probe.placement = context:require(placementContract.capability)
    end,
  })
  probe.placement:place(probe.owner, { window = native.newWindow(1), defaults = { tags = { 'main' } } })
  session:update()
  session:update()
  local warnings = 0
  for _, log in ipairs(native.events.logs) do
    if log[1]:find(MISSING, 1, true) then
      warnings += 1
    end
  end
  expect.equal(warnings, 1, 'the logs of the missing layout')

  local arranged = 0
  probe.layouts:register(probe.owner, {
    name = 'later',
    apply = function(panels)
      arranged = #panels
    end,
  })
  expect.equal(arranged, 1, 'the panels arranged once the layout registers')
  session:close()
end)

test('layout options replace the whole map and preserve code-backed tunings', function()
  local descriptor = require('@lunette-plugins/desktop/arrange/config').schema
  local callback = function(value)
    return value
  end
  local initial = descriptor.parse {
    options = { arc = { radius = 2 }, grid = { columns = 3 } },
    tags = { 'main' },
  }
  local tuned = descriptor.resolve({ options = { custom = { transform = callback } }, tags = {} }, initial)
  expect.equal(tuned.options.arc, nil, 'the replaced arc options')
  expect.equal(tuned.options.grid, nil, 'the replaced grid options')
  expect.equal(tuned.options.custom.transform, callback, 'the callback tuning')
  expect.equal(#tuned.tags, 0, 'the replaced tag list')
end)

return test

local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local layoutsContract = require '@lunette-contracts/layouts'
local placementContract = require '@lunette-contracts/placement'
local panelsContract = require '@lunette-contracts/panels'
local tagsContract = require '@lunette-contracts/tags'
local desktop = require '@lunette-desktop'

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
    {
      id = 'desktop/arrange',
      definition = require('@lunette-plugins/desktop/arrange').definition,
      config = { layout = 'later' },
    },
  }
  local native = session.native
  local probe = {}
  session:use(adapter.define {
    name = 'arrange-test',
    requires = { layoutsContract.capability, placementContract.capability },
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

test(
  'a window in several tags is arranged by the first selected tag, and a window in no tag is arranged last',
  function()
    local session = testing.boot(desktop.compose {
      settings = {
        ['desktop/rules'] = {
          rules = {
            { match = { appId = 'plain' }, properties = { tags = { 'main' } } },
            { match = { appId = 'mail' }, properties = { tags = { 'main', 'mail' } } },
          },
        },
        ['desktop/arrange'] = { layout = 'line' },
      },
      patches = { { id = 'desktop/workspaces', disabled = true } },
    })
    local native = session.native
    local panels = session:observe(panelsContract.capability).service
    local tags = session:observe(tagsContract.capability)
    local layouts = session:observe(layoutsContract.capability)
    local main = tags.service:hold(tags.context, { name = 'main' })
    main:setSelected(tags.context, true)
    -- The layout places its panels one metre apart along x.
    layouts.service:register(layouts.context, {
      name = 'line',
      apply = function(members)
        for index, panel in ipairs(members) do
          panel:setPose(lovr.math.newMat4():translate(index, 0, 0))
        end
      end,
    })
    native.events.windows =
      { native.newWindow(83, 'plain'), native.newWindow(84, 'mail'), native.newWindow(85, 'loose') }
    for _, window in native.events.windows do
      native.emit('onWindowOpened', { window = window })
    end
    local mail = assert(tags.service:find 'mail')
    local panel = assert(panels:forSource(native.events.windows[2]))
    local loose = assert(panels:forSource(native.events.windows[3]))
    local function x(target)
      return (target.pose:getPosition())
    end
    expect.near(x(panel), 2, 1e-5, 'the selected tag arranges it')
    expect.near(x(loose), 1, 1e-5, 'a window in no tag is arranged on its own')
    mail:setSelected(tags.context, true)
    main:setSelected(tags.context, false)
    expect.near(x(panel), 1, 1e-5, 'the other tag arranges it')
    session:close()
  end
)

return test

local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
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

test('a window in several tags is arranged by the first selected tag, with the options of its layout', function()
  local session = testing.boot(desktop.compose {
    patches = {
      {
        id = 'desktop/rules',
        config = { rules = { { match = { appId = 'mail' }, properties = { tags = { 'main', 'mail' } } } } },
      },
      { id = 'desktop/arrange', config = { options = { line = { spacing = 10 } } } },
    },
  })
  local native = session.native
  local panels = session:observe(panelsContract.capability).service
  local tags = session:observe(tagsContract.capability)
  local layouts = session:observe(layoutsContract.capability)
  -- Each layout places its panels `spacing` metres apart along x, by its options or 1.
  for name, sign in { line = 1, reverse = -1 } do
    layouts.service:register(layouts.context, {
      name = name,
      apply = function(members, options)
        local spacing = if options then options.spacing else 1
        for index, panel in ipairs(members) do
          panel:setPose(lovr.math.newMat4():translate(sign * index * spacing, 0, 0))
        end
      end,
    })
  end
  local main = assert(tags.service:find 'main')
  main:setLayout(tags.context, { layout = 'line' })
  native.events.windows = { native.newWindow(83), native.newWindow(84, 'mail') }
  for _, window in native.events.windows do
    native.emit('onWindowOpened', { window = window })
  end
  local mail = assert(tags.service:find 'mail')
  local panel = assert(panels:forSource(native.events.windows[2]))
  local function x()
    return (panel.pose:getPosition())
  end
  expect.near(x(), 20, 1e-5, 'the selected tag arranges it, with its layout options')
  mail:setLayout(tags.context, { layout = 'reverse' })
  expect.near(x(), 20, 1e-5, 'an unselected tag does not take it from a selected one')
  mail:setSelected(tags.context, { selected = true })
  main:setSelected(tags.context, { selected = false })
  expect.near(x(), -1, 1e-5, 'the other tag arranges it, with no options for its layout')
  main:setSelected(tags.context, { selected = true })
  expect.near(x(), 20, 1e-5, 'the first selected tag in order wins')
  session:close()
end)

return test

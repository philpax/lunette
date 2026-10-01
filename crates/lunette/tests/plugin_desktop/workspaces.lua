-- Workspaces: the shipped desktop/workspaces entry inserted by a patch shows
-- the selected workspace's windows and hides the rest, switches with key
-- chords, sends a new window to the workspace in view, leaves a panel another
-- plugin hid hidden, and survives a bindings outage as it was.
local plugin = require '@lunette-plugin'
local tagsContract = require '@lunette-contracts/tags'
local panelsContract = require '@lunette-contracts/panels'

local desktop = require 'fixture/graph' {
  patches = {
    {
      insert = {
        id = 'desktop/workspaces',
        definition = require '@lunette-desktop/workspaces',
        config = {
          workspaces = { { name = 'main', key = '1' }, { name = 'web', key = '2' } },
          modifiers = { 'alt' },
        },
      },
    },
  },
}
assert(
  desktop.instances['desktop/workspaces']:state() == 'active',
  tostring(desktop.instances['desktop/workspaces']:diagnostic())
)

local tags, owner
desktop.runtime
  :use(
    plugin.define {
      name = 'workspaces-probe',
      requires = { tags = tagsContract.capability, panels = panelsContract.capability },
      init = function(context)
        tags, owner = context:require(tagsContract.capability), context
      end,
    },
    {}
  )
  :enable()
local main, web = assert(tags:find 'main'), assert(tags:find 'web')
assert(main.selected and not web.selected, 'the workspace already selected stays selected')

local function chord(key)
  events.held.lalt = true
  lovr.keypressed(key, 0, false)
  events.held = {}
end

-- A window opens on the workspace in view.
local first = newWindow(1)
events.windows = { first }
emit('onWindowOpened', { window = first })
local firstPanel = assert(desktop.panels:forSource(first))
assert(main:has(firstPanel) and not firstPanel.hidden)

-- Switching hides the windows of the workspace left and shows those of the
-- one chosen; a window opened there follows the user.
chord '2'
assert(web.selected and not main.selected, 'the chord selects its workspace')
assert(firstPanel.hidden, 'a window of a workspace not in view is hidden')
local second = newWindow(2)
events.windows = { first, second }
emit('onWindowOpened', { window = second })
local secondPanel = assert(desktop.panels:forSource(second))
assert(web:has(secondPanel) and not main:has(secondPanel), 'a new window joins the workspace in view')
assert(not secondPanel.hidden)
chord '1'
assert(not firstPanel.hidden and secondPanel.hidden, 'switching back shows and hides again')

-- A panel another plugin hid stays hidden when its workspace is shown.
local hiding = firstPanel:setHidden(owner, { hidden = true })
chord '2'
chord '1'
assert(firstPanel.hidden, 'the workspaces withdraw their override rather than show over another')
hiding:dispose()
assert(not firstPanel.hidden)

-- A plugin moves a window between workspaces with an exclusion and an add.
main:exclude(owner, { panel = firstPanel })
web:add(owner, firstPanel)
assert(firstPanel.hidden, 'a window moved to a workspace not in view is hidden')
chord '2'
assert(not firstPanel.hidden and not secondPanel.hidden)

-- A bindings outage leaves the workspaces as they are.
desktop.providers.bindings:disable()
assert(desktop.instances['desktop/workspaces']:state() == 'active')
assert(not firstPanel.hidden and web.selected, 'the workspaces stay as they were')
desktop.providers.bindings:enable()
chord '1'
assert(main.selected and firstPanel.hidden and secondPanel.hidden)

-- Unloading the consumer withdraws every override it holds.
desktop.instances['desktop/workspaces']:disable()
assert(not firstPanel.hidden and not secondPanel.hidden, 'unloading shows every panel it hid')
assert(lovr.quit() == false)

-- A malformed workspace list fails the consumer and names the option.
for _, case in ipairs {
  { config = { workspaces = {} }, message = 'option workspaces names at least one workspace' },
  { config = { workspaces = { { name = 'a', key = '1', colour = 1 } } }, message = 'has an unknown field colour' },
  { config = { workspaces = { { name = 'a', key = '1' }, { name = 'a', key = '2' } } }, message = 'names a twice' },
  { config = { follow = 'yes' }, message = 'option follow is a boolean, not a string' },
} do
  local running = require('@lunette-desktop').start(require('@lunette-desktop').compose {
    patches = {
      {
        insert = {
          id = 'desktop/workspaces',
          definition = require '@lunette-desktop/workspaces',
          config = case.config,
        },
      },
    },
  })
  local instance = running.instances['desktop/workspaces']
  assert(instance:state() == 'failed', instance:state())
  assert(tostring(instance:diagnostic()):find(case.message, 1, true), tostring(instance:diagnostic()))
  running.runtime:close()
end

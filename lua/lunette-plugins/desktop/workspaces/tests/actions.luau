local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local menuContract = require '@lunette-contracts/menu'
local tagsContract = require '@lunette-contracts/tags'
local menuProvider = require '@lunette-plugins/menu'
local test = testing.suite()

-- Selects one tag for the owner and deselects the others.
local function only(tags, owner, chosen)
  for _, tag in tags:all() do
    tag:setSelected(owner, { selected = tag == chosen })
  end
end

local function start()
  local session = testing.boot {
    'frame',
    'theme',
    'panels',
    'tags',
    'rules',
    'placement',
    {
      id = 'desktop/workspaces',
      definition = require '@lunette-plugins/desktop/workspaces',
      config = { workspaces = { { name = 'main' }, { name = 'web' } } },
    },
  }
  return session, session:observe(tagsContract.capability)
end

test('late broker registration reads selection without restarting the workspace parent', function()
  local session, tags = start()
  local main, web = tags.service:find 'main', tags.service:find 'web'
  expect.truthy(main.selected and not web.selected, 'selection exists before the broker')
  only(tags.service, tags.context, web)
  session:use(menuProvider.definition)
  local actions = session:observe(menuContract.capability)
  local rows = actions.service:list()
  expect.equal(#rows, 2, 'late workspace registrations')
  expect.truthy(not rows[1].selected and rows[2].selected, 'late registrations read selected tags')
  expect.equal(session.instances['desktop/workspaces']:state(), 'active', 'the parent stays active')
  session:close()
end)

test('retained callbacks from a substitute broker cannot switch after the child activation ends', function()
  local session, tags = start()
  local callbacks = {}
  local broker = session:use(plugin.define {
    name = 'workspace-retaining-broker',
    provides = { menu = menuContract.capability },
    init = function(context, _config, publish)
      local service = menuProvider.build(context)
      local register = service.register
      service.register = function(self, owner, action)
        callbacks[action.id] = action.run
        return register(self, owner, action)
      end
      publish:provide(menuContract.capability, service)
    end,
  })
  local main, web = tags.service:find 'main', tags.service:find 'web'
  local oldChooseWeb = callbacks['desktop/workspace/web']
  expect.truthy(oldChooseWeb, 'the action callback is registered')
  oldChooseWeb()
  expect.truthy(web.selected and not main.selected, 'the live callback chooses its workspace')
  broker:disable()
  only(tags.service, tags.context, main)
  oldChooseWeb()
  expect.truthy(main.selected and not web.selected, 'the ended child callback is inert')
  broker:enable()
  local currentChooseWeb = callbacks['desktop/workspace/web']
  expect.truthy(currentChooseWeb ~= oldChooseWeb, 'recovery registers a fresh callback')
  oldChooseWeb()
  expect.truthy(main.selected and not web.selected, 'the stale callback stays inert after recovery')
  currentChooseWeb()
  expect.truthy(web.selected and not main.selected, 'the recovered callback chooses its workspace')
  session.instances['desktop/workspaces']:disable()
  currentChooseWeb()
  session:close()
end)

return test

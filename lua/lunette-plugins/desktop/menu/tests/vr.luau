local testing = require '@testing'
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local ui = require '@lunette-contracts/ui'
local menu = require '@lunette-contracts/menu'
local vrUi = require '@testing/vr-ui'
local expect = testing.expect
local test = testing.suite()

local function boot(config)
  local running = vrUi.boot {
    'frame',
    'surfaces',
    'drops',
    'focus',
    'interaction',
    'theme',
    'laser',
    'keyboard',
    'desktop/pointing',
    'ui',
    'menu',
    { id = 'desktop/menu', definition = require '@lunette-plugins/desktop/menu', config = config or {} },
  }
  local env = { running = running, ui = running.session:observe(ui.capability).service }
  env.hand = config and config.hand or 'left'
  env.pointer = if env.hand == 'left' then 'right' else 'left'
  running:pose(env.hand, lovr.math.newMat4():translate(0, 1.2, -0.5))
  running:tracked(env.hand, true)
  running:step()
  running.session:use(adapter.define {
    name = 'testing/actions',
    requires = { menu.capability },
    init = function(context)
      env.owner, env.menu = context, context:require(menu.capability)
    end,
  })
  return env
end

local function register(env, id, options)
  local action = { calls = 0 }
  action.registration = env.menu:register(env.owner, {
    id = id,
    label = options.label or id,
    group = 'Session',
    order = options.order or 10,
    selected = options.selected,
    run = function()
      action.calls += 1
    end,
  })
  return action
end

local function click(env, id, itemId)
  local panel = if id == 'close' then 'desktop/menu/titlebar' else 'desktop/menu'
  env.running:clickControl(env.ui, panel, id, env.pointer, itemId)
end

local function items(env)
  local result = {}
  for _, control in vrUi.describe(env.ui, 'desktop/menu').controls do
    for _, item in control.items or {} do
      result[#result + 1] = item
    end
  end
  return result
end

test(
  'the wrist button opens a list of live actions that run when clicked, and the close button collapses it',
  function()
    local env = boot()
    local draft = register(env, 'draft', { label = 'Draft', selected = true })
    expect.equal(vrUi.describe(env.ui, 'desktop/menu').width, 0.115, 'the menu starts as a wrist button')
    click(env, 'open')
    expect.equal(vrUi.describe(env.ui, 'desktop/menu').width, 0.32, 'the button opens the list')
    expect.equal(items(env)[1].label, 'Session: Draft [selected]', 'a row names its group and state')
    click(env, 'actions', 'draft')
    click(env, 'actions', 'draft')
    expect.equal(draft.calls, 2, 'a row runs each time it is clicked')

    local later = register(env, 'later', { order = 20 })
    draft.registration:update { enabled = false }
    local rows = items(env)
    expect.equal(#rows, 2, 'a new action appears in the open list')
    expect.equal(rows[1].enabled, false, 'a disabled action is shown disabled')
    later.registration:dispose()
    expect.equal(#items(env), 1, 'a removed action leaves the list')

    click(env, 'close')
    expect.equal(vrUi.describe(env.ui, 'desktop/menu').width, 0.115, 'closing returns to the wrist button')
    env.running:close()
  end
)

test('losing the wrist hides the menu and closes the list', function()
  local env = boot()
  click(env, 'open')
  env.running:tracked(env.hand, false)
  env.running:step()
  expect.equal(vrUi.describe(env.ui, 'desktop/menu').visible, false, 'an untracked wrist hides the menu')
  env.running:tracked(env.hand, true)
  env.running:step()
  local description = vrUi.describe(env.ui, 'desktop/menu')
  expect.truthy(description.visible, 'the tracked wrist shows it again')
  expect.equal(description.width, 0.115, 'the list does not reopen')
  env.running:close()
end)

test('the configured hand, size, offset, and haptic strength apply', function()
  local offset = vector.pack(0.2, -0.3, 0.4)
  local env = boot { hand = 'right', size = 0.2, offset = offset, haptic = { strength = 0.4 } }
  local description = vrUi.describe(env.ui, 'desktop/menu')
  expect.equal(description.width, 0.2, 'the size')
  local expected = lovr.math.newMat4(env.running.native.events.controllers.right.pose)
  expected:translate(offset):rotate(math.pi, -0.7071066, 0.0007963618, 0.7071066)
  for index, value in { expected:unpack(true) } do
    expect.near(description.pose[index], value, 1e-5, 'the pose follows the right wrist')
  end
  click(env, 'open')
  expect.equal(env.running.native.events.haptic.strength, 0.4, 'the press pulse strength')
  expect.equal(env.running.native.events.haptic.device, 'hand/left', 'the pulse goes to the pointing hand')
  env.running:close()
end)

return test

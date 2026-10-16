local testing = require '@testing'
local adapter = require '@lunette-plugin/adapter'
local menu = require '@lunette-contracts/menu'
local uiHost = require '@lunette-contracts/ui-host'
local vrUi = require '@testing/vr-ui'
local uiPanels = require '@testing/ui-panels'
local wristMenu = require '@testing/wrist-menu'
local hostFixture = require '@testing/ui-host'
local expect = testing.expect
local test = testing.suite()

type Config = testing.ConfiguredInput<typeof(require('../').define)>
type Environment = {
  running: vrUi.Fixture,
  panels: uiPanels.Recorder,
  hand: vrUi.Hand,
  pointer: vrUi.Hand,
  owner: adapter.Context,
  menu: menu.Service,
}
type ActionOptions = { label: string?, order: number?, selected: boolean?, group: string? }
type Action = { calls: number, registration: menu.Registration }

local PANEL = wristMenu.PANEL

local function boot(config: Config?): Environment
  local panels = uiPanels.new()
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
    panels.entry,
    'ui-standard',
    'menu',
    { id = 'desktop/menu', definition = require('../').definition, config = config or {} },
  }
  local env: Environment = { running = running, panels = panels } :: any
  env.hand = config and config.hand or 'left'
  env.pointer = if env.hand == 'left' then 'right' else 'left'
  running:pose(env.hand, lovr.math.newMat4():translate(0, 1.2, -0.5))
  running:tracked(env.hand, true)
  running:step()
  running.session:use(adapter.define {
    name = 'testing/actions',
    requires = { menu.capability },
    init = function(context: adapter.Context)
      env.owner, env.menu = context, context:require(menu.capability)
    end,
  })
  running:step()
  return env
end

local function register(env: Environment, id: string, options: ActionOptions): Action
  local action: Action = { calls = 0 } :: any
  action.registration = env.menu:register(env.owner, {
    id = id,
    label = options.label or id,
    group = options.group or 'Session',
    order = options.order or 10,
    selected = options.selected,
    run = function()
      action.calls += 1
    end,
  })
  return action
end

local function click(env: Environment, path: string)
  env.panels:click(env.running, PANEL, path, env.pointer)
end

-- Whether the host reports the menu's panel as visible.
local function shown(env: Environment): boolean
  local host = assert(env.running.session:observe(uiHost.capability).service)
  for _, registration in host:inspect().registrations do
    if registration.name == PANEL and registration.live then
      return registration.details.visible == true
    end
  end
  return false
end

local function size(env: Environment): (number, number)
  return assert(env.panels:panel(PANEL)):size()
end

test('the wrist button opens a list of live actions that run when clicked, and Close collapses it', function()
  local env = boot()
  local draft = register(env, 'session/draft', { label = 'Draft', selected = true })
  expect.near((size(env)), 0.115, 1e-6, 'the menu starts as a wrist button')
  click(env, 'open')
  local width, height = size(env)
  expect.near(width, 0.32, 1e-6, 'the button opens the list at the expanded width')
  expect.near(height, 0.4, 1e-6, 'and at the expanded height')
  local row = assert(env.panels:node(PANEL, wristMenu.row 'session/draft'), 'an action has a row keyed by its id')
  expect.equal(row.props.title, 'Draft', 'the row shows the label')
  expect.equal(row.props.detail, 'Session', 'the row shows the group')
  expect.equal(row.props.selected, true, 'the row shows the selected state')
  click(env, wristMenu.row 'session/draft')
  click(env, wristMenu.row 'session/draft')
  expect.equal(draft.calls, 2, 'a row runs each time it is clicked')

  local later = register(env, 'later', { order = 20 })
  draft.registration:update { enabled = false }
  env.running:step()
  expect.truthy(env.panels:node(PANEL, wristMenu.row 'later'), 'a new action appears in the open list')
  row = assert(env.panels:node(PANEL, wristMenu.row 'session/draft'))
  expect.equal(row.props.trailing, 'Unavailable', 'a disabled action says so')
  expect.equal(row.props.onActivate, nil, 'a disabled action takes no input')
  click(env, wristMenu.row 'session/draft')
  expect.equal(draft.calls, 2, 'clicking a disabled action does not run it')
  later.registration:dispose()
  env.running:step()
  expect.equal(env.panels:node(PANEL, wristMenu.row 'later'), nil, 'a removed action leaves the list')

  click(env, 'header/band/close')
  expect.near((size(env)), 0.115, 1e-6, 'closing returns to the wrist button')
  env.running:close()
end)

test('a list longer than the menu scrolls to reach its last action', function()
  local env = boot()
  local actions: { Action } = {}
  for index = 1, 20 do
    actions[index] = register(env, `action-{index}`, { order = index })
  end
  click(env, 'open')
  local last = assert(env.panels:node(PANEL, wristMenu.row 'action-20'))
  local box = assert(env.panels:node(PANEL, 'actions')).parent
  while box and box.kind ~= 'lunette/scroll-view' do
    box = box.parent
  end
  local scroller = assert(box, 'the list scrolls')
  local _, contentHeight = scroller:contentSize()
  expect.truthy(contentHeight > scroller.bounds.height, 'the rows overflow the menu')
  expect.truthy(last:panelBounds().y > select(2, assert(env.panels:panel(PANEL)):size()), 'the last row starts hidden')
  click(env, wristMenu.row 'action-20')
  expect.equal(actions[20].calls, 1, 'the thumbstick scrolls the last action into reach')
  env.running:close()
end)

test('an empty menu says that no actions are registered', function()
  local env = boot()
  click(env, 'open')
  expect.truthy(env.panels:node(PANEL, 'empty'), 'the open menu explains that it is empty')
  env.running:close()
end)

test('losing the wrist hides the menu and closes the list', function()
  local env = boot()
  click(env, 'open')
  env.running:tracked(env.hand, false)
  env.running:step()
  expect.falsy(shown(env), 'an untracked wrist hides the menu')
  env.running:tracked(env.hand, true)
  env.running:step()
  env.running:step()
  expect.truthy(shown(env), 'the tracked wrist shows it again')
  expect.near((size(env)), 0.115, 1e-6, 'the list does not reopen')
  expect.truthy(env.panels:node(PANEL, 'open'), 'the wrist button is shown')
  env.running:close()
end)

-- The menu panel's position in the world.
local function position(env: Environment): vector
  return vector.pack(assert(env.panels:panel(PANEL)):pose():getPosition())
end

-- Drags the open menu by the empty part of its header with the pointing hand's trigger, `dx` metres to the right.
local function dragHeader(env: Environment, dx: number): ()
  local running = env.running
  local function spacer(): any
    return hostFixture.nodeGeometry(assert(env.panels:node(PANEL, 'header/band/spacer')))
  end
  -- Aims twice, because the opened menu lays out again on the wrist after the first frame.
  running:aim(spacer(), 0.5, 0.5, env.pointer)
  running:step()
  local geometry = spacer()
  running:aim(geometry, 0.5, 0.5, env.pointer)
  running:step()
  running:button(env.pointer, 'trigger', true)
  running:step()
  for step = 1, 4 do
    running:aim(geometry, 0.5 + dx * step / 4, 0.5, env.pointer)
    running:step()
  end
  running:button(env.pointer, 'trigger', false)
  running:step()
end

test('dragging the open menu by its header tears it off the wrist until it is closed', function()
  local env = boot()
  local action = register(env, 'session/draft', { label = 'Draft' })
  local wrist = position(env)
  click(env, 'open')
  dragHeader(env, 0.2)
  local torn = position(env)
  -- The wrist turns the menu, so the drag along its width moves it by that distance in the world.
  expect.near(vector.magnitude(torn - wrist), 0.2, 0.01, 'the menu follows the drag')
  env.running:pose(env.hand, lovr.math.newMat4():translate(0.4, 1.1, -0.4))
  env.running:step()
  expect.near(vector.magnitude(position(env) - torn), 0, 1e-6, 'the torn-off menu stays where it was left')
  env.running:tracked(env.hand, false)
  env.running:step()
  expect.truthy(shown(env), 'the torn-off menu stays shown without the wrist')
  click(env, wristMenu.row 'session/draft')
  expect.equal(action.calls, 1, 'the torn-off menu still runs actions')
  env.running:tracked(env.hand, true)
  env.running:step()
  click(env, 'header/band/close')
  env.running:step()
  expect.near((size(env)), 0.115, 1e-6, 'closing returns to the wrist button')
  expect.truthy(vector.magnitude(position(env) - torn) > 0.1, 'and the button is back on the wrist')
  env.running:close()
end)

test('the closed wrist button cannot be grabbed off the wrist', function()
  local env = boot()
  local wrist = position(env)
  local running = env.running
  local geometry = hostFixture.nodeGeometry(assert(env.panels:node(PANEL, 'open')))
  running:aim(geometry, 0.5, 0.5, env.pointer)
  running:step()
  geometry = hostFixture.nodeGeometry(assert(env.panels:node(PANEL, 'open')))
  running:aim(geometry, 0.5, 0.5, env.pointer)
  running:step()
  running:button(env.pointer, 'grip', true)
  running:step()
  running:aim(geometry, 0.7, 0.5, env.pointer)
  running:step()
  expect.near(vector.magnitude(position(env) - wrist), 0, 1e-6, 'the held button stays on the wrist')
  running:button(env.pointer, 'grip', false)
  running:step()
  env.running:close()
end)

test('the configured hand, size, and offset apply, and a press pulses the pointing hand', function()
  local offset = vector.pack(0.2, -0.3, 0.4)
  local env = boot { hand = 'right', size = 0.2, offset = offset }
  expect.near((size(env)), 0.2, 1e-6, 'the size')
  local expected = lovr.math.newMat4(env.running.native.events.controllers.right.pose)
  expected:translate(offset):rotate(math.pi, -0.7071066, 0.0007963618, 0.7071066)
  local actual = { assert(env.panels:panel(PANEL)):pose():unpack(true) }
  for index, value in { expected:unpack(true) } do
    expect.near(actual[index], value, 1e-5, 'the pose follows the right wrist')
  end
  click(env, 'open')
  expect.equal(env.running.native.events.haptic.device, 'hand/left', 'the pulse goes to the pointing hand')
  env.running:close()
end)

return test

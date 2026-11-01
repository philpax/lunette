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
type ActionOptions = { label: string?, selected: boolean?, group: string? }
type Action = { calls: number, registration: menu.Registration }

local PANEL, LIST = wristMenu.PANEL, wristMenu.LIST

local function boot(config: Config?, placed: { [string]: any }?): Environment
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
    {
      id = 'desktop/placement-memory',
      definition = require('@lunette-plugins/layout/placement-memory').definition,
      config = { placed = placed or {} },
    },
    { id = 'desktop/menu', definition = require('../').definition, config = config or {} },
  }
  local env: Environment = { running = running, panels = panels } :: any
  env.hand = config and config.hand or 'left'
  env.pointer = if env.hand == 'left' then 'right' else 'left'
  running:pose(env.hand, wristMenu.facingPose())
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
    selected = options.selected,
    run = function()
      action.calls += 1
    end,
  })
  return action
end

-- Clicks a node on the gauntlet.
local function click(env: Environment, path: string)
  env.panels:click(env.running, PANEL, path, env.pointer)
end

-- Clicks a node on the list.
local function pick(env: Environment, path: string)
  env.panels:click(env.running, LIST, path, env.pointer)
end

-- Whether the host reports a panel of the menu, the gauntlet by default, as visible.
local function shown(env: Environment, name: string?): boolean
  local host = assert(env.running.session:observe(uiHost.capability).service)
  for _, registration in host:inspect().registrations do
    if registration.name == (name or PANEL) and registration.live then
      return registration.details.visible == true
    end
  end
  return false
end

local function size(env: Environment, name: string?): (number, number)
  return assert(env.panels:panel(name or PANEL)):size()
end

test('the wrist button opens a list of live actions that run when clicked, and Close puts it away', function()
  local env = boot()
  local draft = register(env, 'session/draft', { label = 'Draft', selected = true })
  expect.near((size(env)), 0.0575, 1e-6, 'the gauntlet is a wrist button')
  expect.falsy(shown(env, LIST), 'the list starts put away')
  click(env, 'open')
  expect.truthy(shown(env, LIST), 'the button opens the list')
  local width, height = size(env, LIST)
  expect.near(width, 0.32, 1e-6, 'at the expanded width')
  expect.near(height, 0.4, 1e-6, 'and at the expanded height')
  expect.truthy(shown(env), 'the gauntlet stays on the wrist')
  expect.equal(assert(env.panels:node(PANEL, 'open')).props.variant, 'selected', 'its button shows the list is open')
  local row = assert(env.panels:node(LIST, wristMenu.row 'session/draft'), 'an action has a row keyed by its id')
  expect.equal(row.props.title, 'Draft', 'the row shows the label')
  local heading = assert(env.panels:node(LIST, 'actions/%00Session'), 'the group has a heading above its actions')
  expect.equal(heading.props.text, 'SESSION', 'the heading names the group')
  expect.equal(row.props.selected, true, 'the row shows the selected state')
  pick(env, wristMenu.row 'session/draft')
  pick(env, wristMenu.row 'session/draft')
  expect.equal(draft.calls, 2, 'a row runs each time it is clicked')

  local later = register(env, 'later', {})
  draft.registration:update { enabled = false }
  env.running:step()
  expect.truthy(env.panels:node(LIST, wristMenu.row 'later'), 'a new action appears in the open list')
  row = assert(env.panels:node(LIST, wristMenu.row 'session/draft'))
  expect.equal(row.props.trailing, 'Unavailable', 'a disabled action says so')
  expect.equal(row.props.onActivate, nil, 'a disabled action takes no input')
  pick(env, wristMenu.row 'session/draft')
  expect.equal(draft.calls, 2, 'clicking a disabled action does not run it')
  later.registration:dispose()
  env.running:step()
  expect.equal(env.panels:node(LIST, wristMenu.row 'later'), nil, 'a removed action leaves the list')

  pick(env, 'header/band/close')
  expect.falsy(shown(env, LIST), 'Close puts the list away')
  expect.truthy(shown(env), 'and leaves the gauntlet')
  click(env, 'open')
  click(env, 'open')
  expect.falsy(shown(env, LIST), 'the menu button closes an open list too')
  env.running:close()
end)

test('a list longer than the menu scrolls to reach its last action', function()
  local env = boot()
  local actions: { Action } = {}
  for index = 1, 20 do
    actions[index] = register(env, `action-{index}`, {})
  end
  click(env, 'open')
  local last = assert(env.panels:node(LIST, wristMenu.row 'action-20'))
  local box = assert(env.panels:node(LIST, 'actions')).parent
  while box and box.kind ~= 'lunette/scroll-view' do
    box = box.parent
  end
  local scroller = assert(box, 'the list scrolls')
  local _, contentHeight = scroller:contentSize()
  expect.truthy(contentHeight > scroller.bounds.height, 'the rows overflow the menu')
  expect.truthy(last:panelBounds().y > select(2, size(env, LIST)), 'the last row starts hidden')
  pick(env, wristMenu.row 'action-20')
  expect.equal(actions[20].calls, 1, 'the thumbstick scrolls the last action into reach')
  env.running:close()
end)

test('an empty menu says that no actions are registered', function()
  local env = boot()
  click(env, 'open')
  expect.truthy(env.panels:node(LIST, 'empty'), 'the open menu explains that it is empty')
  env.running:close()
end)

test('the closed button and the open header show the time of day', function()
  local env = boot()
  local closed = assert(env.panels:node(PANEL, 'time'), 'the time is shown under the closed button')
  expect.truthy(string.match(closed.props.text, '^%d%d:%d%d:%d%d$'), 'the time reads as hh:mm:ss')
  click(env, 'open')
  local header = assert(env.panels:node(LIST, 'header/band/detail'), 'the open header shows the time')
  expect.truthy(string.match(header.props.text, '^%d%d:%d%d:%d%d$'), 'the header time reads as hh:mm:ss')
  env.running:close()
end)

test('losing the wrist hides the menu and closes the list', function()
  local env = boot()
  click(env, 'open')
  env.running:tracked(env.hand, false)
  env.running:step()
  expect.falsy(shown(env), 'an untracked wrist hides the gauntlet')
  expect.falsy(shown(env, LIST), 'and the list on it')
  env.running:tracked(env.hand, true)
  env.running:step()
  env.running:step()
  expect.truthy(shown(env), 'the tracked wrist shows the gauntlet again')
  expect.falsy(shown(env, LIST), 'the list does not reopen')
  env.running:close()
end)

-- A panel of the menu's position in the world, the gauntlet by default.
local function position(env: Environment, name: string?): vector
  return vector.pack(assert(env.panels:panel(name or PANEL)):pose():getPosition())
end

-- Drags the open menu by the empty part of its header with the pointing hand's trigger, `dx` metres to the right.
local function dragHeader(env: Environment, dx: number): ()
  local running = env.running
  local function spacer(): any
    return hostFixture.nodeGeometry(assert(env.panels:node(LIST, 'header/band/spacer')))
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

test('the open list sits to the right of the gauntlet, as if expanded out of it', function()
  local env = boot()
  click(env, 'open')
  env.running:step()
  local gauntlet = assert(env.panels:panel(PANEL))
  local at = position(env, LIST)
  local offset = vector.pack(lovr.math.mat4(gauntlet:pose()):invert():mul(at.x, at.y, at.z))
  local gauntletWidth, listWidth = size(env), size(env, LIST)
  expect.near(offset.x, gauntletWidth / 2 + 0.01 + listWidth / 2, 1e-6, 'beside its right edge')
  expect.near(offset.y, 0, 1e-6, 'level with its centre')
  env.running:close()
end)

test('dragging the open list by its header tears it off the wrist until it is closed', function()
  local env = boot()
  local action = register(env, 'session/draft', { label = 'Draft' })
  click(env, 'open')
  env.running:step()
  local wrist = position(env, LIST)
  dragHeader(env, 0.2)
  local torn = position(env, LIST)
  -- The wrist turns the list, so the drag along its width moves it by that distance in the world.
  expect.near(vector.magnitude(torn - wrist), 0.2, 0.01, 'the list follows the drag')
  env.running:pose(env.hand, lovr.math.newMat4():translate(0.4, 1.1, -0.4))
  env.running:step()
  expect.near(vector.magnitude(position(env, LIST) - torn), 0, 1e-6, 'the torn-off list stays where it was left')
  env.running:tracked(env.hand, false)
  env.running:step()
  expect.truthy(shown(env, LIST), 'the torn-off list stays shown without the wrist')
  pick(env, wristMenu.row 'session/draft')
  expect.equal(action.calls, 1, 'the torn-off list still runs actions')
  env.running:pose(env.hand, wristMenu.facingPose())
  env.running:tracked(env.hand, true)
  env.running:step()
  pick(env, 'header/band/close')
  expect.falsy(shown(env, LIST), 'closing puts the list away')
  click(env, 'open')
  env.running:step()
  expect.truthy(vector.magnitude(position(env, LIST) - torn) > 0.1, 'and it opens beside the gauntlet again')
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

test('the menu fades and takes no presses while its wrist turns it away from the head', function()
  local env = boot()
  expect.truthy(env.panels:pressable(PANEL), 'a menu facing the head can be pressed')
  -- A half turn of the wrist faces the menu away from the head.
  env.running:pose(env.hand, wristMenu.facingPose():rotate(math.pi, 0, 1, 0))
  for _ = 1, 60 do
    if not env.panels:pressable(PANEL) then
      break
    end
    env.running:step()
  end
  expect.falsy(env.panels:pressable(PANEL), 'a menu turned away cannot be pressed')
  expect.truthy(shown(env), 'it stays shown while it fades')
  click(env, 'open')
  expect.falsy(shown(env, LIST), 'a press at the faded button does not open the list')
  wristMenu.open(env.running, env.panels, env.pointer)
  expect.truthy(shown(env, LIST), 'turning the wrist back lets the button open the list')
  env.running:close()
end)

test('a list left torn off returns torn off, where placement memory saved it', function()
  local env = boot({ open = true, detached = true }, {
    ['desktop/menu'] = { position = vector.create(0.4, 1.3, -0.9), rotation = { 0, 0, 1, 0 } },
  })
  expect.truthy(shown(env, LIST), 'the list is open')
  expect.near(vector.magnitude(position(env, LIST) - vector.pack(0.4, 1.3, -0.9)), 0, 1e-6, 'at the saved placement')
  env.running:tracked(env.hand, false)
  env.running:step()
  expect.truthy(shown(env, LIST), 'a torn-off list stays shown without the wrist')
  env.running:close()
end)

test('the configured hand, size, and offset apply, and a press pulses the pointing hand', function()
  local offset = vector.pack(0.2, -0.3, 0.4)
  local env = boot { hand = 'right', size = 0.2, offset = offset }
  expect.near((size(env)), 0.1, 1e-6, 'the size')
  local expected = lovr.math.newMat4(env.running.native.events.controllers.right.pose)
  expected
    :translate(offset)
    :rotate(math.pi, -0.7071066, 0.0007963618, 0.7071066)
    :rotate(5 * math.pi / 16, 0, 0, 1)
    :translate(0, -0.2, 0.03)
  local actual = { assert(env.panels:panel(PANEL)):pose():unpack(true) }
  for index, value in { expected:unpack(true) } do
    expect.near(actual[index], value, 1e-5, 'the pose follows the right wrist')
  end
  click(env, 'open')
  expect.equal(env.running.native.events.haptic.device, 'hand/left', 'the pulse goes to the pointing hand')
  env.running:close()
end)

return test

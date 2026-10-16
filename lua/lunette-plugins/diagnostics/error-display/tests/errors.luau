local testing = require '@testing'
local menu = require '@lunette-contracts/menu'
local uiHost = require '@lunette-contracts/ui-host'
local vrUi = require '@testing/vr-ui'
local uiPanels = require '@testing/ui-panels'
local expect = testing.expect
local test = testing.suite()

type Config = testing.ConfiguredInput<typeof(require('../').define)>
type Environment = { running: vrUi.Fixture, panels: uiPanels.Recorder, host: uiHost.Service }

local PANEL = 'desktop/errors'
-- The stream's window for identical reports, in seconds.
local WINDOW = 10

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
    'desktop/pointing',
    panels.entry,
    'ui-standard',
    'menu',
    {
      id = 'errors',
      definition = require('@lunette-plugins/diagnostics/error-stream').definition,
      config = { window = WINDOW },
    },
    { id = 'desktop/errors', definition = require('../').definition, config = config or {} },
  }
  running:step()
  local host = assert(assert(running.session):observe(uiHost.capability).service)
  return { running = running, panels = panels, host = host }
end

local function raise(env: Environment, message: string, traceback: string?): ()
  env.running.native.raise(message, traceback or `traceback of {message}`)
  env.running:step()
end

local function shown(env: Environment): boolean
  for _, registration in env.host:inspect().registrations do
    if registration.name == PANEL and registration.live then
      return registration.details.visible == true
    end
  end
  return false
end

local function node(env: Environment, path: string): uiHost.Node?
  return env.panels:node(PANEL, path)
end

local function text(env: Environment, path: string): string?
  local found = node(env, path)
  return if found then found.props.text else nil
end

local function click(env: Environment, path: string): ()
  env.panels:click(env.running, PANEL, path)
end

test('the overlay is hidden until a report arrives, and then shows it at its configured position', function()
  local position = vector.pack(0.2, 1.3, -0.7)
  local env = boot { position = position }
  expect.falsy(shown(env), 'no report, no overlay')
  raise(env, 'fixture overlay error', 'fixture traceback')
  expect.truthy(shown(env), 'a report shows the overlay')
  local x, y, z = assert(env.panels:panel(PANEL)):pose():getPosition()
  expect.near(x, position.x, 1e-5, 'the panel x position')
  expect.near(y, position.y, 1e-5, 'the panel y position')
  expect.near(z, position.z, 1e-5, 'the panel z position')
  expect.equal(text(env, 'body/entries/report-1/summary/message'), 'fixture overlay error')
  expect.equal(text(env, 'body/entries/report-1/traceback'), 'fixture traceback')
  expect.equal(node(env, 'body/entries/report-1/summary/count'), nil, 'a single report shows no count')
  env.running:close()
end)

test('repeated reports collapse into one entry with a count that includes suppressed repeats', function()
  local env = boot()
  raise(env, 'repeated failure')
  raise(env, 'other failure')
  -- The stream suppresses these within its window and reports how many with the next delivered repeat.
  raise(env, 'repeated failure')
  raise(env, 'repeated failure')
  env.running.native.events.time += WINDOW + 1
  raise(env, 'repeated failure')
  expect.equal(text(env, 'body/entries/report-1/summary/count'), '×4', 'one entry counts every repeat')
  expect.equal(node(env, 'body/entries/report-3'), nil, 'a repeat adds no entry')
  local first = assert(node(env, 'body/entries/report-1')):panelBounds()
  local second = assert(node(env, 'body/entries/report-2')):panelBounds()
  expect.truthy(first.y < second.y, 'the latest repeat moves its entry to the top')
  env.running:close()
end)

test('dismissal hides the overlay and clears new reports, and a later report shows only itself', function()
  local env = boot()
  raise(env, 'first failure')
  raise(env, 'second failure')
  click(env, 'header/band/dismiss')
  expect.falsy(shown(env), 'dismissal hides the overlay')
  raise(env, 'third failure')
  expect.truthy(shown(env), 'a later report shows the overlay again')
  expect.truthy(node(env, 'body/entries/report-3'), 'the new report is shown')
  expect.equal(node(env, 'body/entries/report-1'), nil, 'dismissed reports are not new')
  click(env, 'header/band/mode')
  expect.equal(assert(node(env, 'header')).props.title, 'Error history', 'the mode button opens the history')
  for _, id in { 'report-1', 'report-2', 'report-3' } do
    expect.truthy(node(env, `body/entries/{id}`), `the history keeps {id}`)
  end
  env.running:close()
end)

test('the history pages through reports older than one page, by ray and by focus traversal', function()
  local env = boot { page = 2 }
  for index = 1, 5 do
    raise(env, `failure {index}`)
  end
  expect.equal(text(env, 'body/pages/position'), '1–2 of 5', 'the newest page')
  expect.truthy(node(env, 'body/entries/report-5'), 'the newest report leads')
  expect.truthy(assert(node(env, 'body/pages/newer')).props.disabledReason, 'the newest page has nothing newer')
  click(env, 'body/pages/older')
  expect.equal(text(env, 'body/pages/position'), '3–4 of 5', 'Older moves one page back')
  expect.truthy(node(env, 'body/entries/report-3') and node(env, 'body/entries/report-2'))
  expect.equal(node(env, 'body/entries/report-5'), nil, 'the newer page is gone')

  -- Traversal enters the panel at its first control and walks to Older without a pointer.
  local host = env.host
  expect.truthy(host:nextPanel(), 'traversal enters the overlay')
  env.running:step()
  local older = assert(node(env, 'body/pages/older/face'))
  for _ = 1, 8 do
    if older.state.focused then
      break
    end
    host:navigate 'next'
    older = assert(node(env, 'body/pages/older/face'))
  end
  expect.truthy(older.state.focused, 'traversal reaches Older')
  expect.truthy(host:activate(), 'activation pages')
  env.running:step()
  expect.equal(text(env, 'body/pages/position'), '5–5 of 5', 'the oldest page')
  expect.truthy(assert(node(env, 'body/pages/older')).props.disabledReason, 'the oldest page has nothing older')
  env.running:close()
end)

test('dismissal is reachable through focus traversal', function()
  local env = boot()
  raise(env, 'traversed failure')
  local host = env.host
  expect.truthy(host:nextPanel(), 'traversal enters the overlay')
  env.running:step()
  local dismiss = assert(node(env, 'header/band/dismiss/face'))
  for _ = 1, 4 do
    if dismiss.state.focused then
      break
    end
    host:navigate 'next'
    dismiss = assert(node(env, 'header/band/dismiss/face'))
  end
  expect.truthy(dismiss.state.focused, 'traversal reaches Dismiss')
  expect.truthy(host:activate())
  env.running:step()
  expect.falsy(shown(env), 'activation dismisses the overlay')
  env.running:close()
end)

test('the history keeps a bounded number of reports and opens from the menu after dismissal', function()
  local env = boot { history = 2 }
  raise(env, 'oldest failure')
  raise(env, 'middle failure')
  raise(env, 'newest failure')
  click(env, 'header/band/dismiss')
  expect.falsy(shown(env))
  local menus = assert(assert(env.running.session):observe(menu.capability).service)
  local found: menu.Descriptor? = nil
  for _, descriptor in menus:list() do
    if descriptor.id == 'desktop/errors/history' then
      found = descriptor
    end
  end
  local action = assert(found, 'the menu offers the history')
  expect.equal(menus:invoke(action.id, action.token).kind, 'invoked')
  env.running:step()
  expect.truthy(shown(env), 'the menu action opens the overlay')
  expect.equal(assert(node(env, 'header')).props.title, 'Error history')
  expect.equal(node(env, 'body/entries/report-1'), nil, 'the oldest report left the full history')
  expect.truthy(node(env, 'body/entries/report-2') and node(env, 'body/entries/report-3'))
  expect.truthy(
    assert(node(env, 'header/band/mode')).props.disabledReason,
    'with nothing new, the history cannot switch to new reports'
  )
  click(env, 'header/band/dismiss')
  expect.falsy(shown(env), 'dismissal closes the history')
  env.running:close()
end)

return test

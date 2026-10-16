local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local schema = require '@lunette-plugin/schema'
local uiHost = require '@lunette-contracts/ui-host'
local fixture = require './support/vr-manager'
local graph = require '../private/inspection/graph'
local projection = require '../private/inspection/projection'
local test = testing.suite()

type Settings = { title: string }

local ENTRIES = 'main/browser/entries-box/entries/'
local CONFIGURE = 'main/sidebar/configure/'

-- Runs a test body against a booted desktop and closes the session even when the body fails.
local function session(additions: { testing.ComposeEntry }, body: (fixture.Environment) -> ()): ()
  local env = fixture.boot(additions)
  local ok, problem = pcall(body, env)
  env:close()
  if not ok then
    error(problem, 0)
  end
end

local function selectEntry(env: fixture.Environment, id: string): ()
  local path = ENTRIES .. uiHost.keyOf(id)
  env:reveal('main/browser/entries-box', path)
  env:click(path)
end

test('the wrist menu opens the manager, the VR keyboard edits a field, and Apply reconfigures', function()
  local current: Settings?
  local definition = plugin.consumer({
    name = 'vr-workflow-editor',
    schema = schema.object { title = schema.default(schema.string()) 'initial' },
    init = function(_context: plugin.Context, settings: Settings): ()
      current = settings
    end,
  }).definition
  session({ { id = 'vr-workflow-editor', definition = definition } }, function(env: fixture.Environment): ()
    expect.falsy(env:visible(), 'the manager starts hidden')
    env:open()
    expect.truthy(env:visible(), 'Plugins opens the manager')
    selectEntry(env, 'vr-workflow-editor')
    env:click 'main/sidebar/tabs/track/configure'
    env:click(CONFIGURE .. 'rows-box/rows/' .. uiHost.keyOf 'row/s:title')
    expect.truthy(env.services.display:isVisible(), 'the edit field takes the shared keyboard')
    env:key 'All'
    env:key 'Text'
    env:click(CONFIGURE .. 'text/edit-actions/confirm')
    expect.equal(assert(current).title, 'initial', 'Confirm changes only the draft')
    env:click(CONFIGURE .. 'draft/apply')
    expect.equal(assert(current).title, 'next', 'Apply reconfigures the entry')
    env:click 'header/band/close'
    expect.falsy(env:visible(), 'Close hides the manager')
    expect.equal(env.services.focus:focused(), nil, 'Close releases the keyboard route')
  end)
end)

test('Remove asks for confirmation in a dialog, and Cancel keeps the entry', function()
  local definition = plugin.consumer({
    name = 'vr-removable',
    init = function(_context: plugin.Context, _settings: {}): () end,
  }).definition
  session({ { id = 'vr-removable', definition = definition } }, function(env: fixture.Environment): ()
    env:open()
    selectEntry(env, 'vr-removable')
    env:click 'main/sidebar/lifecycle/remove'
    local dialog = env:node('face/header/title', 'desktop/manager/confirm')
    expect.equal(dialog.props.text, 'Remove vr-removable?', 'the dialog names the action and the entry')
    env:click 'main/sidebar/lifecycle/remove'
    expect.truthy(env:entry 'vr-removable', 'the dialog blocks presses on the manager')
    env:click('face/content/actions/cancel', 'desktop/manager/confirm')
    expect.truthy(env.panels['desktop/manager/confirm'].dead, 'Cancel closes the dialog')
    expect.truthy(env:entry 'vr-removable', 'Cancel keeps the entry')
    env:click 'main/sidebar/lifecycle/remove'
    env:click('face/content/actions/confirm', 'desktop/manager/confirm')
    expect.equal(env:entry 'vr-removable', nil, 'confirming removes the entry')
    env:click 'main/sidebar/tabs/track/catalog'
    local catalogRow = 'main/sidebar/catalog/catalog-box/catalog-list/' .. uiHost.keyOf 'vr-removable'
    env:reveal('main/sidebar/catalog/catalog-box', catalogRow)
    env:click(catalogRow)
    env:click 'main/sidebar/catalog/catalog-actions/load'
    expect.equal(assert(env:entry 'vr-removable').state, 'active', 'Catalog loads the removed entry again')
  end)
end)

test('the graph view selects plugins and relationships by pointing at them', function()
  session({}, function(env: fixture.Environment): ()
    env:open()
    env:click 'main/browser/toolbar/view/track/graph-view'
    env.controls:step()
    local manager = assert(env:entry 'desktop/manager')
    local card = 'main/browser/graph/canvas/node-' .. uiHost.keyOf(manager.instanceId)
    env:click(card)
    expect.equal(env:node('header/band/detail').props.text, 'desktop/manager', 'the node selects its entry')
    expect.truthy(
      env:node('main/sidebar/lifecycle/remove/face').props.disabledReason,
      'a protected entry explains why it cannot be removed'
    )
    local before = env:node(card):panelBounds()
    env:click 'main/browser/camera/zoom-in'
    expect.truthy(env:node(card):panelBounds().width > before.width, 'Zoom in enlarges the nodes')
    env:click 'main/browser/filters/mode/track/providers'
    env:click 'main/browser/camera/focus'
    env:click 'main/browser/camera/zoom-out'
    env:click 'main/browser/camera/zoom-out'
    local edge: graph.Edge? = nil
    for _, candidate in projection.snapshot(env.services.composition:snapshot()).graph.edges do
      if candidate.from == manager.instanceId and candidate.kind == 'dependency' then
        edge = candidate
        break
      end
    end
    local bound = assert(edge, 'the manager has a bound provider')
    env:click('main/browser/graph/canvas/edge-' .. uiHost.keyOf(bound.id))
    expect.equal(env:node('main/sidebar/details/lines/line-1').props.text, bound.label, 'the label selects its edge')
  end)
end)

test('Search filters with the VR keyboard and returns the keyboard when it is submitted', function()
  session({}, function(env: fixture.Environment): ()
    env:open()
    env:click 'main/browser/toolbar/search'
    expect.truthy(env.services.display:isVisible(), 'the search field takes the shared keyboard')
    env:key 'Text'
    expect.equal(env:node('footer/status').props.text, 'Search: next', 'typing narrows the search')
    expect.truthy(env:node 'main/browser/entries-box/empty', 'no entry matches the query')
    env:key 'Enter'
    expect.equal(env.panels['desktop/manager']:find 'main/browser/search-field', nil, 'Enter closes the search')
    expect.equal(env.services.focus:focused(), nil, 'the search returns the keyboard')
    env:click 'main/browser/toolbar/clear-filter'
    expect.truthy(env:node('main/browser/entries-box/entries/' .. uiHost.keyOf 'desktop/manager'), 'the filter clears')
  end)
end)

test('the header switches default appearance on and off', function()
  session({}, function(env: fixture.Environment): ()
    env:open()
    expect.falsy(env.services.host:defaultAppearance(), 'the session starts in its configured appearance')
    env:click 'header/band/appearance'
    expect.truthy(env.services.host:defaultAppearance(), 'the header switches default appearance on')
    expect.equal(env:node('header/band/appearance/face/label').props.text, 'Default look: on', 'the button shows it')
    env:click 'header/band/appearance'
    expect.falsy(env.services.host:defaultAppearance(), 'and off again')
  end)
end)

return test

local testing = require '@testing'
local plugin = require '@lunette-plugin'
local schema = require '@lunette-plugin/schema'
local ui = require '@lunette-plugins/ui/react'
local uiHost = require '@lunette-contracts/ui-host'
local uiComponents = require '@lunette-contracts/ui-components'
local pluginManager = require '@lunette-contracts/plugin-manager'
local fixture = require './support/vr-manager'
local expect = testing.expect
local test = testing.suite()

local CONFIGURE = 'main/sidebar/configure/'
local PAGE = CONFIGURE .. 'settings/' .. uiHost.keyOf 'publication-page'

local function poll(env: fixture.Environment): ()
  env.controls:step(1)
  env.controls:step()
end

local function session(body: (fixture.Environment, ui.Store<number>) -> ()): ()
  local counter = ui.store(0)
  local definition = plugin.consumer({
    name = 'publication-page',
    schema = schema.object { count = schema.default(schema.number())(1) },
    requires = { uiHost.capability, uiComponents.capability },
    init = function(context: plugin.Context): ()
      local Page = ui.component('PublicationPage', function(props: pluginManager.SettingsProps): ui.Child
        local c = ui.useComponents()
        local value = ui.useStore(counter)
        if props.entry ~= 'publication-editor' then
          return nil
        end
        return c.Text { key = 'note', text = `Counter {value}` }
      end)
      ui.contribute(context, pluginManager.settings, Page, { components = context:require(uiComponents.capability) })
    end,
  }).definition
  local env = fixture.boot { { id = 'publication-editor', definition = definition } }
  local ok, problem = pcall(function()
    env:open()
    local path = 'main/browser/entries-box/entries/' .. uiHost.keyOf 'publication-editor'
    env:reveal('main/browser/entries-box', path)
    env:click(path)
    env:click 'main/sidebar/tabs/track/configure'
    env.controls:step()
    body(env, counter)
  end)
  env:close()
  if not ok then
    error(problem, 0)
  end
end

test(
  'idle Configure preserves submitted root props across polling while settings pages update independently',
  function()
    session(function(env: fixture.Environment, counter: ui.Store<number>): ()
      local props = env:node('main').props
      for _ = 1, 3 do
        poll(env)
        expect.equal(env:node('main').props, props, 'unchanged polling keeps the submitted props identity')
      end
      counter:set(1)
      env.controls:step()
      expect.equal(env:node(PAGE .. '/body/note').props.text, 'Counter 1', 'the contributed page still updates')
      expect.equal(env:node('main').props, props, 'the outlet update does not need a manager publication')
      env.services.host:setDefaultAppearance(true)
      poll(env)
      expect.equal(env:node('header/band/appearance/face/label').props.text, 'Default look: on')
      local appeared = env:node('main').props
      expect.truthy(appeared ~= props, 'external appearance changes publish the manager')
      poll(env)
      expect.equal(env:node('main').props, appeared, 'the appearance change settles')
      env:click 'header/band/appearance'
      local interacted = env:node('main').props
      expect.equal(env:node('header/band/appearance/face/label').props.text, 'Default look')
      poll(env)
      expect.equal(env:node('main').props, interacted, 'a direct interaction records the rendered appearance')
      env.services.composition:disable 'publication-editor'
      poll(env)
      local entry = env:node('main/browser/entries-box/entries/' .. uiHost.keyOf 'publication-editor')
      expect.equal(entry.props.trailing, 'disabled', 'external lifecycle changes update the real entry list')
    end)
  end
)

test('appearance changes between revision scheduling and rendering track the displayed label', function()
  session(function(env: fixture.Environment): ()
    local host = env.services.host
    local label = 'header/band/appearance/face/label'
    expect.falsy(host:defaultAppearance(), 'the session starts with default appearance off')
    expect.equal(env:node(label).props.text, 'Default look')
    host:setDefaultAppearance(true)
    env.controls:step(1)
    host:setDefaultAppearance(false)
    env.controls:step()
    expect.equal(env:node(label).props.text, 'Default look', 'the queued render reads the later host value')
    host:setDefaultAppearance(true)
    poll(env)
    expect.equal(env:node(label).props.text, 'Default look: on', 'the next poll compares with the displayed value')
    local props = env:node('main').props
    poll(env)
    expect.equal(env:node('main').props, props, 'the displayed appearance settles without another publication')
  end)
end)

test('timer renders continue outside idle Configure and direct interactions still publish', function()
  session(function(env: fixture.Environment): ()
    env:click(CONFIGURE .. 'rows-box/rows/' .. uiHost.keyOf 'row/s:count')
    local props = env:node('main').props
    poll(env)
    expect.truthy(env:node('main').props ~= props, 'an active edit still publishes on every poll')
    env:click(CONFIGURE .. 'text/edit-actions/cancel')
    env.controls:step()
    props = env:node('main').props
    poll(env)
    expect.equal(env:node('main').props, props, 'Cancel returns to idle Configure')
    env:click 'main/sidebar/tabs/track/saved'
    props = env:node('main').props
    poll(env)
    expect.truthy(env:node('main').props ~= props, 'Saved remains unconditional')
    env:click 'header/band/close'
    expect.falsy(env:visible())
    env:open()
    expect.truthy(env:visible(), 'show and hide remain direct interactions')
  end)
end)

return test

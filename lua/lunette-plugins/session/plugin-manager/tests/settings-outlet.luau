local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local uiHost = require '@lunette-contracts/ui-host'
local uiComponents = require '@lunette-contracts/ui-components'
local pluginManager = require '@lunette-contracts/plugin-manager'
local ui = require '@lunette-plugins/ui/react'
local fixture = require './support/vr-manager'
local test = testing.suite()

local ENTRIES = 'main/browser/entries-box/entries/'
local CONFIGURE = 'main/sidebar/configure/'
local PAGE = CONFIGURE .. 'settings/' .. uiHost.keyOf 'test/settings-page'

-- A plugin that contributes a settings page for its own entry.
local contributor = plugin.consumer({
  name = 'test/settings-page',
  requires = { uiHost.capability, uiComponents.capability },
  init = function(context: plugin.Context, _settings: {}): ()
    local components = context:require(uiComponents.capability)
    local Page = ui.component('SettingsPage', function(props: pluginManager.SettingsProps): ui.Child
      local c = ui.useComponents()
      if props.name ~= 'test/settings-page' then
        return nil
      end
      return c.Text { key = 'note', text = `Settings for {props.entry}` }
    end)
    ui.contribute(context, pluginManager.settings, Page, { components = components })
  end,
}).definition

local function selectEntry(env: fixture.Environment, id: string): ()
  local path = ENTRIES .. uiHost.keyOf(id)
  env:reveal('main/browser/entries-box', path)
  env:click(path)
end

test('the Configure tab shows the settings page a plugin contributes for its own entry', function()
  local env = fixture.boot { { id = 'settings-page', definition = contributor } }
  local ok, problem = pcall(function(): ()
    env:open()
    selectEntry(env, 'settings-page')
    env:click 'main/sidebar/tabs/track/configure'
    expect.equal(env:node(PAGE .. '/attribution').props.text, 'test/settings-page', 'the frame names the plugin')
    expect.equal(env:node(PAGE .. '/body/note').props.text, 'Settings for settings-page', 'the page shows its entry')
    selectEntry(env, 'desktop/manager')
    env:click 'main/sidebar/tabs/track/configure'
    expect.truthy(env:node(CONFIGURE .. 'rows-box'), 'an entry with a schema shows its options')
    expect.equal(env.panels['desktop/manager']:find(PAGE), nil, 'the page is absent for another entry')
    local listed = false
    for _, registration in env.services.host:inspect().registrations do
      if registration.kind == 'contribution' and registration.name == 'lunette/manager/settings' then
        listed = registration.details.contributor == 'test/settings-page'
      end
    end
    expect.truthy(listed, 'inspection lists the contribution with its plugin')
  end)
  env:close()
  if not ok then
    error(problem, 0)
  end
end)

return test

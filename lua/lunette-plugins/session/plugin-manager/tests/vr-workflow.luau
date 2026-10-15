local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local schema = require '@lunette-plugin/schema'
local fixture = require './support/vr-manager'
local test = testing.suite()

type Settings = { title: string }

test('the wrist menu opens the manager, the VR keyboard edits a field, and Apply reconfigures', function()
  local current: Settings?
  local definition = plugin.consumer({
    name = 'vr-workflow-editor',
    schema = schema.object { title = schema.default(schema.string()) 'initial' },
    init = function(_context: plugin.Context, settings: Settings)
      current = settings
    end,
  }).definition
  local env = fixture.boot { { id = 'vr-workflow-editor', definition = definition } }
  local ok, problem = pcall(function()
    expect.falsy(env:visible(), 'the manager starts hidden')
    env:open()
    expect.truthy(env:visible(), 'Plugins opens the manager')
    env:item('entries', 'entry/vr-workflow-editor')
    env:click 'configure'
    env:click('rows', 'row/s:title')
    env:click 'edit-field'
    expect.truthy(env.services.display:isVisible(), 'the field shows the shared keyboard')
    env:key 'All'
    env:key 'Text'
    env:click 'confirm'
    expect.equal(current.title, 'initial', 'Confirm changes only the draft')
    env:click 'apply'
    expect.equal(current.title, 'next', 'Apply reconfigures the entry')
    env:click 'close'
    expect.falsy(env:visible(), 'Close hides the manager')
    expect.equal(env.services.focus:focused(), nil, 'Close releases the keyboard route')
  end)
  env:close()
  if not ok then
    error(problem, 0)
  end
end)

return test

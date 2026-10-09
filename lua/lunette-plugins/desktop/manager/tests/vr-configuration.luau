local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local schema = require '@lunette-plugin/schema'
local fixture = require './support/vr-manager'
local suite = testing.suite()

local test = fixture.testCases(suite)

for _, provider in { 'built-in', 'substitute' } do
  test(provider .. ' manager VR configuration and recovery retain drafts and use one shared keyboard', function()
    local current
    local callback = function() end
    local descriptor = schema.object {
      title = schema.default(schema.string()) 'initial',
      count = schema.default(schema.number())(2),
      enabled = schema.default(schema.boolean())(true),
      mode = schema.default(schema.union(schema.literal<<'first'>> 'first', schema.literal<<'second'>> 'second')) 'first',
      items = schema.default(schema.map(schema.number())) {},
      callback = schema.default(schema.callback<<() -> ()>>(callback))(callback),
    }
    local definition = plugin.consumer({
      name = 'vr-configured-consumer',
      schema = descriptor,
      init = function(_context, settings)
        if settings.count == 99 then
          error('fixture count rejects activation', 0)
        end
        current = settings
      end,
    }).definition
    local env = fixture.boot(provider, { { id = 'vr-configured-consumer', definition = definition } })
    env:open()
    local entry = assert(env:entry 'vr-configured-consumer')
    env:click('graph', 'node/' .. entry.instanceId)
    env:click 'configure'
    env:click('rows', 'row/s:count')
    env:click 'edit-field'
    env:key 'All'
    env:key 'Invalid'
    env:click 'confirm'
    expect.equal(current.count, 2, 'numeric rejection does not replace the activation')
    env.controls:discover(env.services.ui, 'desktop/manager', 'edit-field')
    env:key 'All'
    env:key 'Number'
    env:click 'confirm'
    expect.equal(current.count, 2, 'Confirm updates only the retained draft')
    env:click 'apply'
    expect.equal(current.count, 13, 'Apply validates and replaces the activation')
    expect.equal(current.callback, callback, 'opaque callbacks retain identity')
    env:click('rows', 'row/s:title')
    env:click 'edit-field'
    env:key 'All'
    env:key 'Text'
    env:key 'Hide'
    expect.equal(env.services.focus:focused(), nil, 'user-hide releases the field route')
    env:click 'edit-field'
    env:click 'confirm'
    env:click 'apply'
    expect.equal(current.title, 'next', 'blur preserves the edited text')
    env:click('rows', 'row/s:count')
    env:click 'edit-field'
    env:key 'All'
    env:key 'Failure'
    env:click 'confirm'
    env:click 'apply'
    local failed = assert(env:entry 'vr-configured-consumer')
    expect.equal(failed.state, 'failed', 'an accepted request can fail initialization')
    local reports = testing.takeReports()
    expect.equal(#reports, 1, 'the activation failure is explicitly expected')
    expect.truthy(reports[1]:find('fixture count rejects activation', 1, true), reports[1])
    env:click 'recover'
    expect.equal(
      assert(env:entry 'vr-configured-consumer').state,
      'active',
      'Recover restores the previous good request'
    )
    expect.equal(current.count, 13, 'recovery restores the previous validated value')
    expect.equal(current.callback, callback, 'recovery preserves opaque values')
    env:row 'row/s:enabled'
    env:click 'boolean-field'
    env:click 'apply'
    expect.equal(current.enabled, false, 'a shared button edits the boolean')
    env:row 'row/s:mode'
    env:choice 'choice/2'
    env:click 'apply'
    expect.equal(current.mode, 'second', 'a shared choice selects its actual immutable value')
    env:row 'row/s:items'
    env:click 'add'
    env:key 'Map key'
    env:click 'confirm'
    env:click 'apply'
    expect.equal(current.items.added, 0, 'controller Add confirms a map key before Apply')
    env:row 'row/s:items/s:added'
    env:click 'cancel'
    env:click 'remove-value'
    env:click 'apply'
    expect.equal(current.items.added, nil, 'Remove value deletes the selected map member')
    expect.equal(current.callback, callback, 'collection editing preserves opaque sibling identity')
    expect.equal(env:keyboardCount(), 1, 'manager fields share one actual keyboard')
    env:close()
  end)
end

return suite

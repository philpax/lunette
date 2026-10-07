-- Desktop management protects the active VR input and recovery path without protecting optional inspection providers.
local testing = require '@testing'
local expect = testing.expect
local fixture = require './support/protection'
local test = testing.suite()

test('management protects the VR recovery path only', function()
  local service, native = fixture.boot()
  fixture.assertProtected(service)
  for _, id in { 'bindings', 'tags', 'rules', 'errors', 'pacing', 'layouts', 'scale' } do
    expect.falsy(fixture.entries(service)[id].protected, id .. ' remains independently manageable')
    service:disable(id)
    expect.truthy(fixture.entries(service)[id].state ~= 'active', id .. ' can be suspended')
    expect.equal(
      fixture.entries(service)['desktop/manager'].state,
      'active',
      'optional inspection does not stop the manager'
    )
    fixture.assertProtected(service)
    service:enable(id)
    expect.equal(fixture.entries(service)[id].state, 'active', id .. ' reconnects')
  end
  fixture.finish(native)
end)

return test

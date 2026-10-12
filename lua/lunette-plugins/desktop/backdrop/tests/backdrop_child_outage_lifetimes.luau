local testing = require '@testing'
local fixture = require './support/source-controls'
local vrUi = require '@testing/vr-ui'
local expect = testing.expect
local test = testing.suite()

test('backdrop_child_outage_lifetimes', function()
  local env = fixture.boot { settings = { sourceMode = 'attention' } }
  local process = env.native.newProcess(51)
  fixture.window(env, 51, process)
  env.running:step(0.75)
  env.running:step(0)
  env.choice:setResponse(0.25)
  local parent = env.running.session.instances['testing/backdrop-source']
  env.running.session.instances.surfaces:disable()
  expect.equal(parent:state(), 'active', 'the source parent has no surface dependency')
  expect.equal(env.choice.attentionAvailable, false, 'the optional attention child stops')
  expect.equal(env.choice.attended, process, 'an outage retains the selected process')
  env.running.session.instances.surfaces:enable()
  expect.equal(env.choice.attentionAvailable, true, 'the attention child reactivates')
  expect.equal(env.choice.response, 0.25, 'reactivation retains response choices')
  env.ui = env.running.session:observe(require('@lunette-contracts/ui').capability).service
  fixture.open(env)
  expect.truthy(env.choice.frozen, 'the live controls freeze attention')
  env.running.session.instances.ui:disable()
  expect.equal(parent:state(), 'active', 'a UI outage does not disable the source parent')
  expect.equal(env.choice.frozen, false, 'UI cleanup releases the attention freeze')
  expect.equal(env.choice.attentionAvailable, true, 'attention has no UI dependency')
  env.running.session.instances.ui:enable()
  local widgets = env.running.session:observe(require('@lunette-contracts/ui').capability).service
  expect.equal(vrUi.describe(widgets, 'desktop/backdrop/controls').visible, false, 'recovered controls start closed')
  env.running.session.instances.menu:disable()
  expect.equal(parent:state(), 'active', 'menu removal only interrupts its controls child')
  env.running.session.instances.menu:enable()
  env.running:close()
end)

return test

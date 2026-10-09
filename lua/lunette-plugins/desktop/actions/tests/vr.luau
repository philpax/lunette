local testing = require '@testing'
local display = require '@lunette-contracts/keyboard-display'
local menuFixture = require '@lunette-plugins/desktop/menu/tests/support/fixture'
local expect = testing.expect
local test = testing.suite()

test('UI invokes the keyboard action and renders external visibility changes', function()
  local env = menuFixture.boot 'ui'
  env.running.session:use(require '@lunette-plugins/desktop/keyboard')
  env.running.session:use(require '@lunette-plugins/desktop/actions')
  local service = env.running.session:observe(display.capability).service
  env:open()
  env:click('actions', 'desktop/keyboard/toggle')
  expect.equal(service:isVisible(), true)
  env.running:step()
  local _, row = env.running:discover(env.ui, 'desktop/menu', 'actions', 'desktop/keyboard/toggle')
  expect.truthy(row.label:find('[selected]', 1, true))
  expect.truthy(service:hide())
  env.running:step()
  local _, hidden = env.running:discover(env.ui, 'desktop/menu', 'actions', 'desktop/keyboard/toggle')
  expect.equal(hidden.label:find('[selected]', 1, true), nil)
  env:click('actions', 'desktop/keyboard/toggle')
  expect.equal(service:isVisible(), true)
  env:click('actions', 'desktop/keyboard/toggle')
  expect.equal(service:isVisible(), false)
  env:click 'close'
end)

return test

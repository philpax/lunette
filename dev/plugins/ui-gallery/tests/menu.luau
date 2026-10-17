local testing = require '@testing'
local fixture = require '@testing/ui-host'
local menu = require '@lunette-contracts/menu'
local expect = testing.expect
local test = testing.suite()

test('the gallery starts closed, opens from the wrist menu, and closes from its header', function()
  local state = fixture.boot {
    standard = true,
    plugins = {
      require('@lunette-plugins/menu/action-registry').definition,
      require('@lunette-plugins/ui/notifications').definition,
      require('../init').definition,
    },
  }
  local menus = assert(assert(state.fixture.session):observe(menu.capability).service)
  state.fixture:step()
  expect.equal(state.service:find 'Widget gallery:body', nil, 'the gallery starts closed')
  expect.equal(menus:invoke('dev/ui-gallery/open').kind, 'invoked')
  state.fixture:step()
  state.fixture:step()
  local close = assert(state.service:find 'Widget gallery:header/band/close', 'the open gallery has a close button')
  state.fixture:click(fixture.nodeGeometry(close), 0.5, 0.5)
  state.fixture:step()
  expect.equal(state.service:find 'Widget gallery:body', nil, 'the close button closes the gallery')
  expect.equal(menus:invoke('dev/ui-gallery/open').kind, 'invoked')
  state.fixture:step()
  state.fixture:step()
  expect.truthy(state.service:find 'Widget gallery:body', 'the action opens the gallery again')
  expect.equal(menus:invoke('dev/ui-gallery/open').kind, 'invoked')
  state.fixture:step()
  expect.equal(state.service:find 'Widget gallery:body', nil, 'the action closes the open gallery')
  state.fixture:close()
end)

return test

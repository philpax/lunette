local testing = require '@testing'
local adapter = require '@lunette-plugin/adapter'
local schema = require '@lunette-plugin/schema'
local uiHost = require '@lunette-contracts/ui-host'
local uiComponents = require '@lunette-contracts/ui-components'
local fixture = require '@testing/ui-host'
local expect = testing.expect
local test = testing.suite()

local OUTLET = uiHost.outlet {
  name = 'test/standard-outlet',
  version = { major = 1, minor = 0 },
  props = schema.object { entry = schema.string() },
  attributed = true,
}

test('the Outlet constructor places an outlet that frames a contribution of standard kinds', function()
  local contributor = adapter.define {
    name = 'test/standard-contributor',
    requires = { uiHost.capability, uiComponents.capability },
    init = function(context: adapter.Context): ()
      local c = context:require(uiComponents.capability)
      context:require(uiHost.capability):contribute(context, OUTLET, {
        bind = function(mount: uiHost.OutletMount): ()
          mount:bind {
            render = function(): ()
              mount:submit(c.Text { key = 'note', text = `settings for {mount:props().entry}` })
            end,
          }
        end,
      })
    end,
  }
  local state = fixture.boot { standard = true, width = 0.4, height = 0.4, plugins = { contributor } }
  local c = assert(state.components)
  fixture.show(
    state,
    c.Panel {
      c.Body {
        key = 'body',
        c.Outlet { key = 'settings', outlet = OUTLET, props = { entry = 'desktop/backdrop' }, maxHeight = 0.1 },
      },
    }
  )
  local key = uiHost.keyOf 'test/standard-contributor'
  local note = assert(state.panel:find(`body/settings/{key}/body/note`), 'the contribution renders in the frame')
  expect.equal(note.props.text, 'settings for desktop/backdrop')
  local attribution = assert(state.panel:find(`body/settings/{key}/attribution`))
  expect.equal(attribution.props.text, 'test/standard-contributor', 'the frame names the contributor')
  state.fixture:close()
end)

return test

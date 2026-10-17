local testing = require '@testing'
local fixture = require '@testing/ui-host'
local standard = require '@lunette-plugins/ui/standard'
local expect = testing.expect
local test = testing.suite()

local function face(node: any): number
  local lines = assert(node:textLines())
  return assert(lines[1].glyphs[1]).face
end

test('bundled families select distinct native faces and keep them after the provider unloads', function()
  local state = fixture.boot { width = 0.4, height = 0.3 }
  local session = assert(state.fixture.session)
  local provider = session:use(standard.definition, {})
  local observed = session:observe(require('@lunette-contracts/ui-components').capability)
  local c = assert(observed.service)
  local element = c.Panel {
    c.Body {
      key = 'body',
      c.Text { key = 'sans', text = 'Text', style = 'body' },
      c.Text { key = 'mono', text = 'Text', style = 'mono' },
    },
  }
  fixture.show(state, element)
  local sans = face(assert(state.panel:find 'body/sans'))
  local mono = face(assert(state.panel:find 'body/mono'))
  expect.truthy(sans ~= mono, 'the font bytes supply the actual sans and mono families')
  provider:disable()
  local data = assert(lovr.filesystem.read '@lunette-plugins/ui/standard/fonts/IBMPlexSans-Regular.ttf')
  expect.equal(require('@lunette').loadLayoutFont(data), 0, 'unloading keeps the native font bytes held')
  provider:enable()
  fixture.show(state, element)
  expect.equal(face(assert(state.panel:find 'body/sans')), sans, 'reload keeps the sans face')
  expect.equal(face(assert(state.panel:find 'body/mono')), mono, 'reload keeps the mono face')
  state.fixture:close()
end)

test('an unreadable bundled font reports its file through the provider failure', function()
  local state = fixture.boot { width = 0.4, height = 0.3 }
  local read = lovr.filesystem.read
  local missing = '@lunette-plugins/ui/standard/fonts/IBMPlexSans-Regular.ttf'
  lovr.filesystem.read = function(path: string): string?
    return if path == missing then nil else read(path)
  end
  local session = assert(state.fixture.session)
  local instance = session:use(standard.definition, {})
  lovr.filesystem.read = read
  expect.truthy(string.find(
    assert(testing.diagnostic(session.runtime, instance)),
    `ui: the font '{missing}' could not be read`,
    1,
    true
  ))
  expect.equal(#testing.takeReports(), 1, 'the provider reports the read failure once')
  state.fixture:close()
end)

return test

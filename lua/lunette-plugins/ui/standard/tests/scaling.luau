local testing = require '@testing'
local fixture = require '@testing/ui-host'
local expect = testing.expect
local test = testing.suite()

test('a text scale change lays text out again at the new size', function()
  local state = fixture.boot { standard = true, width = 0.4, size = 'content' }
  local c = assert(state.components)
  fixture.show(state, c.Panel { c.Body { key = 'body', c.Text { key = 'text', text = 'Readable' } } })
  local text = assert(state.panel:find 'body/text')
  local before = text.bounds.height
  local _, panelBefore = state.panel:size()
  state.service:setAccessibility { textScale = 2 }
  state.fixture:step()
  state.fixture:step()
  expect.near(text.bounds.height, before * 2, before * 0.1, 'the text is twice as tall')
  local _, panelAfter = state.panel:size()
  expect.truthy(panelAfter > panelBefore, 'and the content-sized panel grows')
  state.fixture:close()
end)

return test

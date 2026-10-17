local testing = require '@testing'
local fixture = require '@testing/ui-host'
local expect = testing.expect
local test = testing.suite()

test('traversal updates keyboard intent on entering and leaving text focus', function()
  local state = fixture.boot { width = 0.3, height = 0.2, standard = true }
  local c = assert(state.components)
  fixture.show(
    state,
    c.Panel {
      c.Body {
        key = 'body',
        c.Button { key = 'before', label = 'Before' },
        c.TextField { key = 'text', value = '', onChange = function() end },
        c.Button { key = 'after', label = 'After' },
      },
    }
  )
  local observed = assert(state.fixture.session):observe(require('@lunette-contracts/focus').capability)
  local intent = false
  assert(observed.service):onChanged(assert(observed.context), {
    run = function(change)
      intent = change.wantsKeyboard
    end,
  })
  expect.truthy(state.service:nextPanel())
  expect.falsy(intent, 'buttons do not request the keyboard')
  expect.truthy(state.service:navigate 'next')
  expect.truthy(intent, 'traversing into a field requests the shared keyboard')
  fixture.click(state, 'body/after/face')
  expect.truthy(intent, 'a pointer button beside the field does not end text entry')
  expect.truthy(state.service:navigate 'next')
  expect.falsy(intent, 'traversing out of text releases keyboard intent')
  expect.truthy(state.service:navigate 'previous')
  expect.truthy(intent, 'returning to text requests it again')
  expect.truthy(state.service:dismiss())
  expect.falsy(intent, 'Escape clears the field keyboard intent')
  state.fixture:close()
end)

return test

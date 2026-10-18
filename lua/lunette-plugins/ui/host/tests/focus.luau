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
    run = function(change: any)
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

test('closing a panel during focus target replacement cancels text focus', function()
  local state = fixture.boot { width = 0.3, height = 0.2, standard = true }
  local c = assert(state.components)
  fixture.show(
    state,
    c.Panel {
      c.Body {
        key = 'body',
        c.Button { key = 'before', label = 'Before' },
        c.TextField { key = 'text', value = '', onChange = function() end },
      },
    }
  )
  local text = assert(state.panel:find 'body/text')
  local observed = assert(state.fixture.session):observe(require('@lunette-contracts/focus').capability)
  local service = assert(observed.service)
  local intent = false
  local closing = false
  local closed = false
  local listener = service:onChanged(assert(observed.context), {
    run = function(change: any)
      intent = change.wantsKeyboard
      if closing and change.kind == 'none' then
        closing = false
        closed = true
        state.panel:destroy()
      end
    end,
  })
  expect.truthy(state.service:nextPanel())
  local previous = assert(service:focused())
  closing = true
  local accepted = state.service:navigate 'next'
  expect.truthy(closed, 'the real focus listener closes the panel during replacement')
  expect.truthy(previous.dead, 'the old focus target is disposed')
  expect.falsy(service:focused(), 'the closed panel has no focused route')
  expect.falsy(intent, 'the closed panel does not request a keyboard')
  for _, registration in service:inspect().registrations do
    expect.falsy(registration.source == 'focus.register', 'the closed panel leaves no target registration')
  end
  expect.falsy(text:focus(), 'a dead node cannot reacquire a focus target')
  expect.falsy(accepted, 'the interrupted traversal does not acquire focus')
  listener:dispose()
  expect.equal(#state.fixture.native.events.reported, 0, 'focus teardown reports no callback errors')
  state.fixture:close()
end)

for _, replacement in { 'text', 'after' } do
  test(`reentrant focus on {replacement} supersedes an in-flight target replacement`, function()
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
    local target = assert(state.panel:find(if replacement == 'text' then 'body/text' else 'body/after/face'))
    local observed = assert(state.fixture.session):observe(require('@lunette-contracts/focus').capability)
    local service = assert(observed.service)
    local replacing = false
    local replaced = false
    local intent = false
    local acquired = nil
    local listener = service:onChanged(assert(observed.context), {
      run = function(change: any)
        intent = change.wantsKeyboard
        if replacing and change.wantsKeyboard then
          replacing = false
          if replacement == 'text' then
            replaced = assert(state.panel:find 'body/after/face'):focus() and target:focus()
          else
            replaced = target:focus()
          end
          acquired = service:focused()
        end
      end,
    })
    expect.truthy(state.service:nextPanel())
    replacing = true
    local accepted = state.service:navigate 'next'
    for _, reported in state.fixture.native.events.reported do
      error(reported.message .. '\n' .. reported.traceback)
    end
    expect.truthy(replaced, 'the real focus listener acquires replacement focus')
    expect.truthy(acquired, 'the real focus service accepts the replacement target')
    expect.falsy(accepted, 'the superseded traversal does not acquire focus')
    expect.equal(service:focused(), acquired, 'the reentrant focus target remains current')
    expect.truthy(target.state.focused, 'the replacement node retains panel focus')
    expect.equal(intent, replacement == 'text', 'keyboard intent follows the replacement node')
    local registrations = 0
    for _, registration in service:inspect().registrations do
      if registration.source == 'focus.register' then
        registrations += 1
      end
    end
    expect.equal(registrations, 1, 'only the replacement target remains registered')
    listener:dispose()
    state.fixture:close()
  end)
end

return test

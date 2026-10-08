local testing = require '@testing'
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local focus = require '@lunette-contracts/focus'
local keys = require '@lunette-contracts/keys'
local substitute = require '@testing/ui-substitute'
local expect = testing.expect
local test = testing.suite()

local function withProvider(provider, run)
  local state = { native = testing.native() }
  local running = testing.start {
    'theme',
    'surfaces',
    'focus',
    provider,
    {
      id = 'owner',
      definition = plugin.define {
        name = 'testing/provider-text-owner',
        requires = { ui = ui.capability, focus = focus.capability },
        init = function(context)
          state.owner = context
          state.ui = context:require(ui.capability)
          state.focus = context:require(focus.capability)
          state.source = state.focus:newSource(context)
          state.panel = state.ui:newPanel(context, {
            name = 'Provider text',
            width = 1,
            height = 1,
            logicalWidth = 200,
            logicalHeight = 200,
          })
        end,
      },
    },
  }
  local ok, message = xpcall(function()
    run(state, running)
  end, function(raised)
    return debug.traceback(tostring(raised), 2)
  end)
  local closed, cleanup = pcall(function()
    running:close()
    state.native.assertResourcesReleased()
  end)
  if not ok then
    if not closed then
      message ..= '\nfixture cleanup: ' .. tostring(cleanup)
    end
    error(message, 0)
  end
  if not closed then
    error(cleanup, 0)
  end
end

local function shared(name, run)
  for _, provider in
    {
      { name = 'built-in', entry = 'ui' },
      { name = 'substitute', entry = { id = 'ui', definition = substitute.definition } },
    }
  do
    test(provider.name .. ': ' .. name, function()
      withProvider(provider.entry, run)
    end)
  end
end

local function field(state, options)
  options.id = options.id or 'draft'
  options.bounds = { x = 10, y = 10, width = 180, height = 30 }
  return state.panel:textField(state.owner, options)
end

local function oneReport(state, first, label, message)
  local reports = state.native.events.reported
  expect.equal(#reports - first, 1, 'one widget callback report')
  local report = reports[first + 1]
  expect.truthy(report.message:find('testing/provider-text-owner', 1, true), 'report names the caller owner')
  expect.truthy(report.message:find(label, 1, true), 'report names the callback')
  expect.truthy(report.message:find(message, 1, true), 'report preserves the callback error')
  expect.equal(#testing.takeReports(), 0)
end

shared('empty committed text preserves every draft and selection without callbacks', function(state)
  local changes, validations = 0, 0
  local input = field(state, {
    onChange = function()
      changes += 1
    end,
    validate = function()
      validations += 1
    end,
  })
  expect.truthy(input:focus())
  for _, value in { '', 'a', 'é👩🏽‍💻x' } do
    input:setValue(value)
    local boundaries = lunette.textBoundaries(value)
    for _, caret in boundaries do
      for _, anchor in boundaries do
        input:setSelection(caret, anchor)
        local before = validations
        for _ = 1, 2 do
          expect.equal(state.source:text('').kind, 'consumed')
          expect.equal(input:value(), value)
          local actualCaret, actualAnchor = input:selection()
          expect.equal(actualCaret, caret, 'empty commit preserves the caret')
          expect.equal(actualAnchor, anchor, 'empty commit preserves the anchor')
          expect.equal(validations, before, 'empty commit does not validate')
          expect.equal(changes, 0, 'empty commit does not publish a change')
        end
      end
    end
  end
  expect.equal(#testing.takeReports(), 0)
end)

shared('cancel commits blur before an error and preserves the draft and selection', function(state)
  local cancelled, focusedDuring = nil, true
  local input = field(state, {
    value = 'draft',
    onCancel = function(value)
      cancelled = value
      focusedDuring = state.focus:focused() ~= nil
      error 'cancel notification failed'
    end,
  })
  input:setSelection(3, 1)
  expect.truthy(input:focus())
  local first = #state.native.events.reported
  local result = state.source:key { code = keys.CODES.escape }
  oneReport(state, first, 'onCancel', 'cancel notification failed')
  expect.equal(result.kind, 'consumed')
  expect.equal(cancelled, 'draft')
  expect.falsy(focusedDuring, 'blur precedes the cancel notification')
  expect.equal(state.focus:focused(), nil, 'an error does not retain focus')
  expect.equal(input:value(), 'draft')
  local caret, anchor = input:selection()
  expect.equal(caret, 3)
  expect.equal(anchor, 1)
  expect.equal(state.source:text('ignored').kind, 'unhandled')
end)

shared('cancel can refocus the same field without a stale blur', function(state)
  local input, focusedDuring, refocused = nil, true, false
  input = field(state, {
    value = 'draft',
    onCancel = function()
      focusedDuring = state.focus:focused() ~= nil
      refocused = input:focus()
    end,
  })
  expect.truthy(input:focus())
  expect.equal(state.source:key({ code = keys.CODES.escape }).kind, 'consumed')
  expect.falsy(focusedDuring, 'the callback observes the committed blur')
  expect.truthy(refocused)
  expect.truthy(state.focus:focused(), 'the callback focus is not undone')
  expect.equal(state.source:text('!').kind, 'consumed')
  expect.equal(input:value(), 'draft!')
  expect.equal(#testing.takeReports(), 0)
end)

shared('cancel can replace its field and focus the replacement', function(state)
  local input, replacement, focusedDuring = nil, nil, true
  input = field(state, {
    value = 'old',
    onCancel = function()
      focusedDuring = state.focus:focused() ~= nil
      input:destroy()
      replacement = field(state, { value = 'new' })
      expect.truthy(replacement:focus())
    end,
  })
  expect.truthy(input:focus())
  expect.equal(state.source:key({ code = keys.CODES.escape }).kind, 'consumed')
  expect.falsy(focusedDuring, 'blur precedes replacement acquisition')
  expect.truthy(input.dead)
  expect.truthy(state.focus:focused(), 'the replacement keeps its focus')
  expect.equal(state.source:text('!').kind, 'consumed')
  expect.equal(replacement:value(), 'new!')
  expect.equal(#testing.takeReports(), 0)
end)

shared('validation replacement cannot publish an older edit or submit a newer draft', function(state)
  local input, changes, submits = nil, 0, 0
  input = field(state, {
    validate = function(value)
      if value == 'replace' or value == 'submit' then
        input:setValue 'newer'
        return 'Older validation error.'
      end
    end,
    onChange = function()
      changes += 1
    end,
    onSubmit = function()
      submits += 1
    end,
  })
  expect.truthy(input:focus())
  expect.equal(state.source:text('replace').kind, 'consumed')
  expect.equal(input:value(), 'newer')
  expect.equal(changes, 0, 'replacement suppresses the older onChange')
  expect.equal(state.source:key({ code = keys.CODES.enter }).kind, 'consumed')
  expect.equal(submits, 1, 'the newer valid draft is not left with an older error')
  input:setValue ''
  expect.equal(state.source:text('submit').kind, 'consumed')
  expect.equal(changes, 0)
  local replaceOnSubmit = true
  local other
  other = field(state, {
    id = 'submit-reentry',
    value = 'ready',
    validate = function()
      if other and replaceOnSubmit then
        replaceOnSubmit = false
        other:setValue 'replacement'
      end
    end,
    onSubmit = function()
      submits += 1
    end,
  })
  expect.truthy(other:focus())
  expect.equal(state.source:key({ code = keys.CODES.enter }).kind, 'consumed')
  expect.equal(other:value(), 'replacement')
  expect.equal(submits, 1, 'reentrant validation does not submit the replacement')
  expect.equal(#testing.takeReports(), 0)
end)

shared('validation selection and external error reentry suppress older notifications', function(state)
  local input, changes, submits, errors = nil, 0, 0, 0
  input = field(state, {
    validate = function(value)
      if value == 'select' then
        input:setSelection(1, 3)
      elseif value == 'error' then
        errors += 1
        input:setError('Newer external error ' .. errors .. '.')
      end
    end,
    onChange = function()
      changes += 1
    end,
    onSubmit = function()
      submits += 1
    end,
  })
  expect.truthy(input:focus())
  expect.equal(state.source:text('select').kind, 'consumed')
  expect.equal(changes, 0, 'selection replacement invalidates the older edit')
  local caret, anchor = input:selection()
  expect.equal(caret, 1)
  expect.equal(anchor, 3)
  input:setValue ''
  expect.equal(state.source:text('error').kind, 'consumed')
  expect.equal(changes, 0, 'external error invalidates the older edit')
  expect.equal(state.source:key({ code = keys.CODES.enter }).kind, 'consumed')
  expect.equal(submits, 0, 'the external error remains authoritative')
  expect.equal(#testing.takeReports(), 0)
end)

shared('validation destruction suppresses change callbacks and future routing', function(state)
  local input, changes = nil, 0
  input = field(state, {
    validate = function(value)
      if value == 'destroy' then
        input:destroy()
      end
    end,
    onChange = function()
      changes += 1
    end,
  })
  expect.truthy(input:focus())
  expect.equal(state.source:text('destroy').kind, 'consumed')
  expect.truthy(input.dead)
  expect.equal(changes, 0)
  expect.equal(state.focus:focused(), nil)
  expect.equal(state.source:text('ignored').kind, 'unhandled')
  expect.equal(#testing.takeReports(), 0)
end)

shared('validation owner shutdown suppresses notifications after the owner ends', function(state, running)
  local changes = 0
  local input = field(state, {
    validate = function(value)
      if value == 'shutdown' then
        running.instances.owner:disable()
      end
    end,
    onChange = function()
      changes += 1
    end,
  })
  expect.truthy(input:focus())
  expect.equal(state.source:text('shutdown').kind, 'consumed')
  expect.truthy(input.dead)
  expect.equal(changes, 0)
  expect.equal(state.focus:focused(), nil)
  expect.equal(#testing.takeReports(), 0)
end)

shared('change and submit errors report once while delivery stays consumed', function(state)
  local changed, submitted = nil, nil
  local input = field(state, {
    onChange = function(value)
      changed = value
      error 'change notification failed'
    end,
    onSubmit = function(value)
      submitted = value
      error 'submit notification failed'
    end,
  })
  expect.truthy(input:focus())
  local first = #state.native.events.reported
  local result = state.source:text 'draft'
  oneReport(state, first, 'onChange', 'change notification failed')
  expect.equal(result.kind, 'consumed')
  expect.equal(changed, 'draft')
  expect.equal(input:value(), 'draft', 'the draft is committed before notification')
  first = #state.native.events.reported
  result = state.source:key { code = keys.CODES.enter }
  oneReport(state, first, 'onSubmit', 'submit notification failed')
  expect.equal(result.kind, 'consumed')
  expect.equal(submitted, 'draft')
  expect.truthy(state.focus:focused(), 'notification failures do not implicitly blur')
  expect.equal(#testing.takeReports(), 0)
end)

return test

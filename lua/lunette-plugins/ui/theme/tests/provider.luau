local testing = require '@testing'
local contract = require '@lunette-contracts/theme'
local palette = require '../private/palette'
local expect = testing.expect
local test = testing.suite()

-- Starts the provider over whichever fake native API is installed, so two sessions can share its save files.
local function start(config: { [string]: any }?): (testing.Session, contract.Service, any)
  local session = testing.start { { id = 'theme', definition = require('../').definition, config = config } }
  local observed = session:observe(contract.capability)
  return session, assert(observed.service), observed.context
end

test('the configured mode and accent choose the starting theme', function()
  testing.native()
  local session, service = start { mode = 'light', accent = { 0.9, 0.55, 0.65 } }
  local current = service:current()
  expect.equal(current.mode, 'light', 'the configured mode')
  local expected = palette.resolve('light', { 0.9, 0.55, 0.65, 1 })
  expect.equal(current.colors.accent[1], expected.colors.accent[1], 'the configured accent, guarded')
  expect.equal(service:base().mode, 'dark', 'the base theme is the dark mode')
  session:close()
end)

test('each change resolves a new theme and tells every listener, and a repeated value changes nothing', function()
  testing.native()
  local session, service, owner = start()
  local heard: { contract.Theme } = {}
  service:onChanged(owner, {
    run = function(theme: contract.Theme)
      heard[#heard + 1] = theme
    end,
  })
  local first = service:current()
  service:setMode 'light'
  expect.equal(#heard, 1, 'a mode change is heard')
  expect.truthy(heard[1] == service:current() and heard[1] ~= first, 'with the new theme')
  service:setMode 'light'
  expect.equal(#heard, 1, 'setting the same mode again changes nothing')
  service:setAccent { 0.2, 0.8, 0.3 }
  expect.equal(#heard, 2, 'an accent change is heard')
  local body = service:current().type.body.size
  service:setOptions { textScale = 1.5, highContrast = true }
  expect.equal(#heard, 3, 'an options change is heard')
  expect.near(service:current().type.body.size, body * 1.5, 1e-9, 'the text scale applies')
  expect.near(service:base().type.body.size, body * 1.5, 1e-9, 'to the base theme as well')
  service:setOptions { textScale = 1.5, highContrast = true }
  expect.equal(#heard, 3, 'the same options change nothing')
  expect.raises(function()
    service:setMode('sepia' :: any)
  end, 'is not a mode')
  expect.raises(function()
    service:setOptions { textScale = 3 }
  end, 'text scale')
  session:close()
end)

test('a chosen mode and accent are saved, and a later session starts with them over the configured ones', function()
  local native = testing.native()
  local session, service = start { mode = 'dark' }
  service:setMode 'light'
  service:setAccent { 0.9, 0.55, 0.65 }
  session:close()
  expect.truthy(native.events.files['theme.settings'], 'the choices were saved')
  local later, restored = start { mode = 'dark' }
  expect.equal(restored:current().mode, 'light', 'the saved mode wins over the configured one')
  expect.near(restored:accent()[1], 0.9, 1e-9, 'and the saved accent')
  later:close()
end)

test('an invalid saved value falls back to the configuration, and a newer file is left unchanged', function()
  local native = testing.native()
  native.events.files['theme.settings'] =
    'return { version = 1, settings = { mode = "sepia", accent = { 0.2, 0.3, 0.4 } } }'
  local session, service = start { mode = 'light' }
  expect.equal(service:current().mode, 'light', 'an invalid mode keeps the configured one')
  expect.near(service:accent()[2], 0.3, 1e-9, 'a valid accent still applies')
  session:close()
  local future = 'return { version = 2, settings = { mode = "dark" } }'
  native.events.files['theme.settings'] = future
  session, service = start { mode = 'light' }
  service:setMode 'dark'
  expect.equal(native.events.files['theme.settings'], future, 'a newer file is never overwritten')
  session:close()
end)

return test

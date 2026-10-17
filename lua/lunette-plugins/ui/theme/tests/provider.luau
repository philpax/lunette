local testing = require '@testing'
local contract = require '@lunette-contracts/theme'
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
  expect.near(service:accent()[1], 0.9, 1e-9, 'the configured accent')
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

test('a chosen mode and accent are saved settings, which a later session starts with', function()
  testing.native()
  local management = require '@lunette-plugin/management'
  local saved = {
    overrides = {} :: { [string]: { [string]: unknown } },
    write = function() end,
    report = function(message: string)
      error(message, 0)
    end,
    storable = function(): boolean
      return true
    end,
  }
  local service: contract.Service? = nil
  local viewer = require('@lunette-plugin/adapter').define {
    name = 'theme-viewer',
    requires = { contract.capability },
    init = function(context: any)
      service = context:require(contract.capability)
    end,
  }
  local entries = {
    { id = 'theme', definition = require('../').definition, config = { mode = 'dark' } },
    { id = 'viewer', definition = viewer },
  }
  local running = management.start(entries, { saved = saved })
  local first = assert(service)
  first:setMode 'light'
  first:setAccent { 0.9, 0.55, 0.65 }
  expect.equal(saved.overrides.theme.mode, 'light', 'the mode is saved')
  expect.near((saved.overrides.theme.accent :: any)[1], 0.9, 1e-9, 'and the accent')
  running.runtime:close()
  service = nil
  local later = management.start(entries, { saved = saved })
  local restored = assert(service)
  expect.equal(restored:current().mode, 'light', 'the saved mode wins over the configured one')
  expect.near(restored:accent()[1], 0.9, 1e-9, 'and the saved accent')
  later.runtime:close()
end)

return test

-- A setting saved in an earlier session applies when the desktop starts. The desktop starts once per Lua state, so
-- this is apart from the test that saves.
local testing = require '@testing'
local expect = testing.expect
local adapter = require '@lunette-plugin/adapter'
local desktop = require '@lunette-desktop'
local theme = require '@lunette-contracts/theme'
local versionedFile = require '@lunette-plugins/storage/versioned-file'
local test = testing.suite()

-- Starts the desktop with an observer of the theme, and answers the theme service.
local function start(): theme.Service
  local service: theme.Service? = nil
  local observer = adapter.define {
    name = 'saved-settings-observer',
    requires = { theme.capability },
    init = function(context: adapter.Context)
      service = context:require(theme.capability)
    end,
  }
  desktop.run {
    settings = { theme = { mode = 'dark' } },
    patches = { { insert = { id = 'saved-settings-observer', definition = observer } } },
  }
  lovr.load()
  return assert(service, 'the observer sees the theme')
end

test('a saved theme mode replaces the configured mode at the next start', function()
  local native = testing.native()
  native.events.files['settings.saved'] = versionedFile.render({ entries = { theme = { mode = 'light' } } }, 1)
  local service = start()
  expect.equal(service:current().mode, 'light', 'the saved mode wins over the configured one')
  local shutdown = testing.host.shutdown()
  expect.equal(#shutdown, 0, table.concat(shutdown, '\n'))
end)

return test

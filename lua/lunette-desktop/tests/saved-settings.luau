-- A setting changed in a session is saved by the desktop and applies at the next start.
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

test('a theme mode chosen in a session is saved in the save directory', function()
  local native = testing.native()
  local first = start()
  expect.equal(first:current().mode, 'dark', 'the configured mode applies')
  first:setMode 'light'
  local text = assert(native.events.files['settings.saved'], 'the desktop saves the change')
  local loaded = versionedFile.parse(text, 'settings.saved', 1)
  assert(loaded.kind == 'data', 'the file parses')
  expect.equal(loaded.data.entries.theme.mode, 'light', 'the file holds the saved mode')
  local shutdown = testing.host.shutdown()
  expect.equal(#shutdown, 0, table.concat(shutdown, '\n'))
end)

return test

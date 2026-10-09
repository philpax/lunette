local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local desktop = require '@lunette-desktop'
local menuContract = require '@lunette-contracts/menu'
local themeContract = require '@lunette-contracts/theme'

local test = testing.suite()

test('the theme example runs and starts with Dusk, offering it in place of Arcade', function()
  local native = testing.native()
  local events = native.events
  testing.host.useConfiguration 'examples/theme'
  require 'main'
  lovr.load()
  events.logs = {}
  lovr.update(0.016)
  expect.equal(#events.logs, 0, 'Dusk is registered by the first frame')
  expect.equal(lovr.quit(), false, 'quit does not veto')

  local observed = {}
  local session = testing.boot(
    desktop.compose {
      patches = {
        { insert = { id = 'example/theme/dusk', definition = require('dusk').definition } },
        { id = 'desktop/theme', config = { preset = 'dusk' } },
        { id = 'theme/arcade', disabled = true },
        {
          insert = {
            id = 'example-theme-observer',
            definition = adapter.define {
              name = 'example-theme-observer',
              requires = { menuContract.capability, themeContract.capability },
              init = function(context)
                observed.menu = context:require(menuContract.capability)
                observed.theme = context:require(themeContract.capability)
              end,
            },
          },
        },
      },
    },
    { native = native }
  )
  local choices = {}
  for _, action in observed.menu:list() do
    if action.group == 'Appearance' then
      choices[#choices + 1] = action.label .. (if action.selected then '*' else '')
    end
  end
  expect.equal(table.concat(choices, ', '), 'Theme: Dark, Theme: Light, Theme: Dusk*', 'the offered themes')
  local focus = observed.theme:current().theme.colors.focus
  expect.equal(focus[1], 1, 'the Dusk focus colour')
  expect.equal(focus[2], 0.60, 'the Dusk focus colour')
  session:close()
end)

return test

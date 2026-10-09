-- The wrist menu opens a movable third-party form using the configured UI provider.
local desktop = require '@lunette-desktop'

desktop.run {
  patches = {
    { insert = { id = 'example/ui/form', definition = require './form' } },
    { insert = { id = 'example/ui/theme-registration', definition = require './theme-registration' } },
  },
}

-- The wrist menu opens a movable third-party form built on the UI host.
local desktop = require '@lunette-desktop'

desktop.run {
  patches = {
    { insert = { id = 'example/ui/form', definition = require('./form').definition } },
  },
}

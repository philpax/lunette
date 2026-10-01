-- The shipped desktop with three plugins inserted. docs/guide/writing-plugins.md
-- walks through each of them.
require('@lunette-desktop').run {
  patches = {
    { insert = { id = 'hello', definition = require './hello' } },
    { insert = { id = 'clock', definition = require './clock-provider' } },
    { insert = { id = 'uptime', definition = require './uptime', config = { prefix = 'running for' } } },
  },
}

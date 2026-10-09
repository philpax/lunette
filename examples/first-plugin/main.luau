require('@lunette-desktop').run {
  patches = {
    { insert = { id = 'hello', definition = require('./hello').definition } },
    { insert = { id = 'clock', definition = require('./clock-provider').definition } },
    { insert = { id = 'uptime', definition = require('./uptime').definition, config = { prefix = 'running for' } } },
  },
}

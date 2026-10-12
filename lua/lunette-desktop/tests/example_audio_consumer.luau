local testing = require '@testing'

testing.host.useConfiguration 'examples/audio-backdrop'
return require 'tests/consumer'

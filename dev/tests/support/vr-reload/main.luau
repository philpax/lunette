-- Each production source reload observes the actual development configuration with fresh modules.
local testing = require '@testing'

testing.host.useConfiguration 'dev'
local ok, failure = pcall(function()
  local observer = require 'tests/support/development-observer'
  observer.load()
end)
testing.host.useConfiguration 'dev/tests/support/vr-reload'
if not ok then
  error(failure, 0)
end

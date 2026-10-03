-- Covers the save at quit in the shipped desktop: a write that is refused or raises is reported, and the quit
-- is not vetoed.
local testing = require '@testing'
local expect = testing.expect
local desktop = require '@lunette-desktop'

local test = testing.suite()

for _, mode in ipairs { 'refuse', 'throw' } do
  test('a save at quit whose write answers ' .. mode .. ' is reported without vetoing the quit', function()
    local session = testing.boot(desktop.entries())
    local native, events = session.native, session.native.events
    events.windows = { native.newWindow(1) }
    native.emit('onWindowOpened', { window = events.windows[1] })
    events.timeline = {}
    events.writeMode = mode
    expect.equal(session:quit(), false, 'the quit is not vetoed')
    expect.equal(events.timeline[1], 'save', 'the quit saves first')
    expect.equal(#events.reported, 1, 'the failed save is reported')
    expect.truthy(events.reported[1].message:find('lovr.quit: ', 1, true), events.reported[1].message)
    session:close()
  end)
end

return test

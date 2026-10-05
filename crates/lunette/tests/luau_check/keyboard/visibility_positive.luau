local lunette = require '@lunette'
local keyboard = require '@lunette-contracts/keyboard'

local function reason(change: keyboard.VisibilityChange): string
  local visible: boolean = change.visible
  if change.reason == 'show' then
    assert(visible)
    return 'show'
  elseif change.reason == 'hide' then
    return 'hide'
  elseif change.reason == 'user-hide' then
    return 'user-hide'
  else
    local destroyed: 'destroy' = change.reason
    return destroyed
  end
end

local function consume(service: keyboard.Service, owner: keyboard.Owner, window: lunette.Window)
  local events: { keyboard.VisibilityChange } = {
    { visible = true, reason = 'show' },
    { visible = false, reason = 'hide' },
    { visible = false, reason = 'user-hide' },
    { visible = false, reason = 'destroy' },
  }
  local options: keyboard.Options = {
    target = function(): (lunette.Seat?, lunette.Sink?)
      return lunette.defaultSeat(), window.sink
    end,
    onVisibilityChanged = function(change: keyboard.VisibilityChange): ()
      assert(#reason(change) > 0)
    end,
  }
  local board: keyboard.Keyboard = service:new(owner, options)
  board:setVisible(true)
  local typed: boolean = board:typeText 'fixture'
  local pressed: boolean = board:pressKey(30)
  local destroyed: boolean = board:destroy()
  return { events = events, typed = typed, pressed = pressed, destroyed = destroyed }
end

return consume

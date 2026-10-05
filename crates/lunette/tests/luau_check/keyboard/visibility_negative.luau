local focus = require '@lunette-contracts/focus'
local keyboard = require '@lunette-contracts/keyboard'

local function misuse(
  service: keyboard.Service,
  owner: keyboard.Owner,
  focused: focus.Service,
  options: keyboard.Options,
  change: keyboard.VisibilityChange
)
  local function oldFocused(): focus.TargetHandle?
    return focused:focused()
  end
  service:new(owner, { onVisibilityChanged = function(_visible: boolean): () end }) -- reject.
  service:new(owner, { onVisibilityChanged = 'show' }) -- reject.
  service:new(owner, { target = oldFocused }) -- reject.
  local invalidReason: keyboard.VisibilityChange = { visible = false, reason = 'toggle' } -- reject.
  local invalidVisible: keyboard.VisibilityChange = { visible = 'yes', reason = 'show' } -- reject.
  local missingReason: keyboard.VisibilityChange = { visible = false } -- reject.
  local missingVisible: keyboard.VisibilityChange = { reason = 'hide' } -- reject.
  change.visible = true -- reject.
  change.reason = 'show' -- reject.
  options.onVisibilityChanged = function(_change: keyboard.VisibilityChange): () end -- reject.
  return { invalidReason, invalidVisible, missingReason, missingVisible }
end

return misuse

local plugin = require '@lunette-plugin'
local display = require '@lunette-contracts/keyboard-display'
local focus = require '@lunette-contracts/focus'

local function misuse(
  service: display.Service,
  owner: display.Owner,
  change: display.Change,
  listener: display.Listener,
  context: plugin.Context
)
  service.show = service.hide -- reject.
  service:show(owner) -- reject.
  service.hide(owner) -- reject.
  service:onChanged({}, listener) -- reject.
  service:onChanged(owner, function(_change: display.Change): () end) -- reject.
  service:onChanged(owner, { run = function(_visible: boolean): () end }) -- reject.
  listener.run = function(_change: display.Change): () end -- reject.
  change.visible = true -- reject.
  change.reason = 'show' -- reject.
  local wrongReason: display.Change = { visible = false, reason = 'focus' } -- reject.
  local wrongResult: number = service:show() -- reject.
  local wrongToken: focus.Service = context:require(display.capability) -- reject.
  return { wrongReason, wrongResult, wrongToken }
end

return misuse

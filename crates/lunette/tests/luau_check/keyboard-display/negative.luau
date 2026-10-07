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
  service.dead = false -- reject.
  service.show = service.hide -- reject.
  service:show(owner) -- reject.
  service.hide(owner) -- reject.
  service:onChanged({}, listener) -- reject.
  service:onChanged(owner, function(_change: display.Change): () end) -- reject.
  service:onChanged(owner, { run = function(_visible: boolean): () end }) -- reject.
  listener.run = function(_change: display.Change): () end -- reject.
  change.visible = true -- reject.
  change.reason = 'show' -- reject.
  change.target = nil -- reject.
  change.revision = 0 -- reject.
  local wrongReason: display.Change = { visible = false, reason = 'focus', revision = 1 } -- reject.
  local missingRevision: display.Change = { visible = false, reason = 'hide' } -- reject.
  local wrongTarget: display.Change = { visible = false, reason = 'hide', revision = 1, target = service } -- reject.
  local wrongResult: number = service:show() -- reject.
  local wrongToken: focus.Service = context:require(display.capability) -- reject.
  type Narrow = { read dead: boolean, read extra: boolean }
  local receiver: (display.Service) -> boolean = function(_self: Narrow): boolean -- reject.
    return true
  end
  return { wrongReason, missingRevision, wrongTarget, wrongResult, wrongToken, receiver }
end

return misuse

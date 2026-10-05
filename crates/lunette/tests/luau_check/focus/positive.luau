local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local focus = require '@lunette-contracts/focus'

local function consume(service: focus.Service, owner: focus.Owner, window: lunette.Window)
  local function changed(change: focus.Change): ()
    local revision: number = change.revision
    local kind: 'none' | 'native' | 'local' = change.kind
    local wantsKeyboard: boolean = change.wantsKeyboard
    local target: focus.TargetHandle? = change.target
    assert(revision >= 0 and (kind ~= 'none' or not wantsKeyboard))
    if target then
      assert(not target.dead)
    end
  end

  local receiver: focus.Receiver = {
    key = function(event: focus.KeyEvent): boolean
      local code: number = event.code
      local modifiers: { read [number]: string } = event.modifiers
      local source: 'virtual' | 'physical' = event.source
      local isRepeat: boolean = event.isRepeat
      return code > 0 and #modifiers == 0 and source == 'virtual' and not isRepeat
    end,
    text = function(text: string): boolean
      return #text > 0
    end,
    onFocus = changed,
    onBlur = changed,
  }
  local localTarget: focus.Target = {
    kind = 'local',
    receiver = receiver,
    keymapSeat = lunette.defaultSeat(),
    wantsKeyboard = true,
  }
  local handle: focus.TargetHandle = service:register(owner, localTarget)
  local focused: boolean = handle:focus()
  local current: focus.TargetHandle? = service:focused()
  local revision: number = service:revision()
  local effect: plugin.Effect = service:onChanged(owner, { run = changed })
  assert(focused and current == handle and revision >= 0)

  local sink: lunette.Sink? = window.sink
  if sink then
    local nativeTarget: focus.Target = { kind = 'native', seat = lunette.defaultSeat(), sink = sink }
    local nativeHandle: focus.TargetHandle = service:register(owner, nativeTarget)
    assert(not nativeHandle.dead)
  end

  local blurred: boolean = handle:blur()
  local destroyed: boolean = handle:destroy()
  return { effect = effect, blurred = blurred, destroyed = destroyed, receiver = receiver }
end

return consume

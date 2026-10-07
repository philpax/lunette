local plugin = require '@lunette-plugin'
local display = require '@lunette-contracts/keyboard-display'
local focus = require '@lunette-contracts/focus'

local function consume(service: display.Service, owner: display.Owner): plugin.Effect
  local dead: boolean = service.dead
  local show: boolean = service:show()
  local hide: boolean = service:hide()
  local toggle: boolean = service:toggle()
  local visible: boolean = service:isVisible()
  local changed: display.Listener = {
    run = function(change: display.Change): ()
      local isVisible: boolean = change.visible
      local reason: 'show' | 'hide' | 'user-hide' | 'destroy' = change.reason
      local target: focus.TargetHandle? = change.target
      local revision: number = change.revision
      if target then
        local targetDead: boolean = target.dead
        assert(targetDead or revision >= 0)
      end
      assert(isVisible or reason ~= 'show')
    end,
  }
  local effect: plugin.Effect = service:onChanged(owner, changed)
  assert(not dead or not (show or hide or toggle or visible))
  return effect
end

local implementation: display.Service = {
  dead = false,
  show = function(_self: display.Service): boolean
    return true
  end,
  hide = function(_self: display.Service): boolean
    return true
  end,
  toggle = function(_self: display.Service): boolean
    return true
  end,
  isVisible = function(_self: display.Service): boolean
    return false
  end,
  onChanged = function(_self: display.Service, _owner: display.Owner, _listener: display.Listener): plugin.Effect
    return { dispose = function(_effect: plugin.Effect): () end }
  end,
}

local function token(context: plugin.Context): display.Service
  return context:require(display.capability)
end

return { consume = consume, implementation = implementation, token = token }

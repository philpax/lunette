local plugin = require '@lunette-plugin'
local menu = require '@lunette-contracts/menu'

return function(state)
  state.registrations, state.updates = {}, {}
  return {
    id = 'menu',
    definition = plugin.define {
      name = 'testing/retained-menu',
      provides = { menu = menu.capability },
      init = function(context, _, provide)
        local byEffect = {}
        provide:provide(menu.capability, {
          register = function(_self, owner, action)
            context:checkOwner(owner)
            local record = { owner = owner, action = action }
            state.registrations[#state.registrations + 1] = record
            local effect = context:acquire(owner, function()
              return function()
                byEffect[record.effect] = nil
              end
            end)
            record.effect = effect
            byEffect[effect] = record
            return effect
          end,
          update = function(_self, owner, effect, value)
            local record = byEffect[effect]
            if not record or record.owner ~= owner or not context:owns(owner) then
              return false
            end
            state.updates[#state.updates + 1] = { owner = owner, effect = effect, value = value }
            return true
          end,
        })
      end,
    },
  }
end

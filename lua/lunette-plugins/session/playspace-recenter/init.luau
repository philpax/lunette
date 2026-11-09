-- Exposes runtime playspace recentering without changing world-space content or workspace placement.
local plugin = require '@lunette-plugin'
local menu = require '@lunette-contracts/menu'
local frame = require '@lunette-contracts/frame'

export type Config = {}
export type Settings = {}

type Status = 'available' | 'unsupported' | 'untracked' | 'unavailable'

local function reason(status: Status): string?
  if status == 'available' then
    return nil
  elseif status == 'unsupported' then
    return 'The headset runtime does not support playspace recentering.'
  elseif status == 'untracked' then
    return 'Head tracking is unavailable.'
  else
    return 'The headset runtime is unavailable.'
  end
end

return plugin.consumer<<Config, Settings>> {
  name = 'desktop/recenter',
  requires = { menu.capability, frame.capability },
  init = function(context: plugin.Context, _settings: Settings): ()
    local menuService: menu.Service = context:require(menu.capability)
    local frameService: frame.Service = context:require(frame.capability)
    local pending = false
    local registration: menu.Registration
    local function refresh(): boolean
      local status = lovr.headset.getRecenterStatus()
      registration:update {
        disabledReason = if pending then 'Playspace recenter is pending.' else reason(status) or false,
      }
      return status == 'available'
    end
    registration = menuService:register(context, {
      id = 'desktop/playspace/recenter',
      label = 'Recenter playspace',
      group = 'Session',
      disabledReason = reason(lovr.headset.getRecenterStatus()),
      run = function(): ()
        if not context:active() or pending or not refresh() then
          return
        end
        -- Pointing finishes in one coordinate frame; the next input phase invalidates tracking before scene work.
        pending = true
        refresh()
      end,
    })
    frameService:onUpdate(context, {
      phase = 'input',
      run = function(_dt: number): ()
        if not context:active() then
          return
        end
        local requested = pending
        pending = false
        if refresh() and requested then
          lovr.headset.recenter()
          refresh()
        end
      end,
    })
  end,
}

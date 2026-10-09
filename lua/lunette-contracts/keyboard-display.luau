-- Owns one session keyboard's visibility. Local focus can request it without making it manually visible.
local plugin = require '@lunette-plugin'
local focus = require '@lunette-contracts/focus'

local display = {}

export type Owner = plugin.Owner
export type Change = {
  read visible: boolean,
  read reason: 'show' | 'hide' | 'user-hide' | 'destroy',
  read target: focus.TargetHandle?,
  read revision: number,
}
export type Listener = { read run: (Change) -> () }
export type Service = {
  read dead: boolean,
  read show: (Service) -> boolean,
  read hide: (Service) -> boolean,
  read toggle: (Service) -> boolean,
  read isVisible: (Service) -> boolean,
  read onChanged: (Service, Owner, Listener) -> plugin.Effect,
}
export type Capability = plugin.Capability<Service>

display.capability = plugin.capability<<Service>> { name = 'lunette/keyboard-display', schema = 1 }

return display

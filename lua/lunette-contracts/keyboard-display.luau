-- Owns one session keyboard's visibility. Local focus can request it without making it manually visible.
local plugin = require '@lunette-plugin'
local keyboard = require '@lunette-contracts/keyboard'
local inspection = require '@lunette-contracts/inspection'

local display = {}

export type Owner = plugin.Owner
export type Change = keyboard.VisibilityChange
export type Listener = { read run: (Change) -> () }
export type Service = {
  read inspect: (Service) -> inspection.Snapshot,
  read show: (Service) -> boolean,
  read hide: (Service) -> boolean,
  read toggle: (Service) -> boolean,
  read isVisible: (Service) -> boolean,
  read onChanged: (Service, Owner, Listener) -> plugin.Effect,
}
export type Capability = plugin.Capability<Service>

display.capability = plugin.capability<<Service>> { name = 'lunette/keyboard-display', version = 1 }

return display

local plugin = require '@lunette-plugin'
local menu = require '@lunette-contracts/menu'

type Implementation = menu.Service & { read implementation: string }

local function badReceiver(_self: Implementation, _owner: menu.Owner, _action: menu.Action): plugin.Effect
  error 'fixture'
end
local receiver: (menu.Service, menu.Owner, menu.Action) -> plugin.Effect = badReceiver -- reject.

local callback: menu.Action = {
  id = 'fixture.callback',
  label = 'Callback',
  run = function(_id: string): () end, -- reject.
}
local mistyped: menu.Action = { id = 'fixture.state', label = 'State', enabled = 'yes', run = function(): () end } -- reject.
local token: menu.Registration = { kind = 'other-registration' } -- reject.
local result: menu.Result = { kind = 'failed' } -- reject.
local unknownResult: menu.Result = { kind = 'other' } -- reject.

local function writes(service: menu.Service, owner: menu.Owner, effect: plugin.Effect, action: menu.Action): ()
  action.enabled = false -- reject.
  local row = service:list()[1]
  row.label = 'Changed' -- reject.
  row.registration.kind = 'menu-registration' -- reject.
  service:list()[1] = row -- reject.
  service:register(effect, action) -- reject.
  service:update(owner, row.registration, { selected = true }) -- reject.
  service:invoke(row.id, effect) -- reject.
  local response = service:invoke(row.id)
  local message: string = response.message -- reject.
  print(message)
end

return { receiver, callback, mistyped, token, result, unknownResult, writes }

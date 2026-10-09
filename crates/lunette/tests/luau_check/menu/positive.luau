local plugin = require '@lunette-plugin'
local menu = require '@lunette-contracts/menu'
local inspection = require '@lunette-contracts/inspection'
local provider = require '@lunette-plugins/menu'

type RequiredState = {
  read id: string,
  read label: string,
  read group: string,
  read order: number,
  read enabled: boolean,
  read selected: boolean,
  read run: () -> (),
}
type MinimalAction = { read id: string, read label: string, read run: () -> () }
type RequiredFlags = { read enabled: boolean, read selected: boolean }
type MinimalState = {}
type Implementation = menu.Service & { read implementation: string }

local function covariance(
  required: RequiredState,
  minimal: MinimalAction,
  flags: RequiredFlags,
  absent: MinimalState
): (menu.Action, menu.Action, menu.State, menu.State)
  local complete: menu.Action = required
  local defaults: menu.Action = minimal
  local present: menu.State = flags
  local missing: menu.State = absent
  return complete, defaults, present, missing
end

local function substitute(context: plugin.Context): menu.Service
  local service: Implementation = {
    implementation = 'fixture',
    register = function(_self: menu.Service, owner: menu.Owner, _action: menu.Action): plugin.Effect
      return context:acquire(owner, function(): () -> ()
        return function(): () end
      end)
    end,
    update = function(_self: menu.Service, _owner: menu.Owner, _effect: plugin.Effect, _state: menu.State): boolean
      return false
    end,
    list = function(_self: menu.Service): { read [number]: menu.Descriptor }
      local rows: { menu.Descriptor } = {}
      return table.freeze(rows)
    end,
    invoke = function(_self: menu.Service, _id: string, _expectedRegistration: menu.Registration?): menu.Result
      return { kind = 'unavailable' }
    end,
    inspect = function(_self: menu.Service): inspection.Snapshot
      return inspection.snapshot {}
    end,
  }
  return service
end

local function use(service: menu.Service, owner: menu.Owner, action: menu.Action): string
  local effect: plugin.Effect = service:register(owner, action)
  local changed: boolean = service:update(owner, effect, { enabled = true })
  assert(changed or not changed)
  local rows: { read [number]: menu.Descriptor } = service:list()
  local row = rows[1]
  local token: menu.Registration = row.registration
  local kind: 'menu-registration' = token.kind
  assert(kind == 'menu-registration')
  local result: menu.Result = service:invoke(row.id, token)
  local byId: menu.Result = service:invoke(row.id)
  assert(byId.kind == 'invoked' or byId.kind == 'unavailable' or byId.kind == 'failed')
  effect:dispose()
  if result.kind == 'failed' then
    return result.message
  elseif result.kind == 'invoked' then
    return row.label
  end
  return 'unavailable'
end

local configured: plugin.Patch = plugin.configure('menu', provider.definition) {}
local definition: plugin.Definition<{}> = plugin.define<<{}>> {
  name = 'fixture/menu-substitute',
  provides = { menu = menu.capability },
  init = function(context: plugin.Context, _settings: {}, publish: plugin.Publisher): ()
    local service: menu.Service = substitute(context)
    publish:provide(menu.capability, service)
  end,
}

return { covariance, substitute, use, configured, definition }

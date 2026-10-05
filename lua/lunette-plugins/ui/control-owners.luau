-- One provider activation reserves owner-local control ids across all of its panels.
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'

local owners = {}

export type Reservation = {
  read identity: ui.OwnerIdentity,
  read release: () -> (),
}
type Entry = {
  identity: ui.OwnerIdentity,
  ids: { [string]: Reservation },
}
export type Registry = { [ui.Owner]: Entry }

function owners.reserve(registry: Registry, context: plugin.Context, owner: ui.Owner, id: string): Reservation
  context:checkOwner(owner)
  local entry = registry[owner]
  if not entry then
    local identity: ui.OwnerIdentity = { kind = 'ui-owner' }
    local created: Entry = { identity = table.freeze(identity), ids = {} }
    registry[owner] = created
    local ok, failure = pcall(function(): ()
      context:acquire(owner, function(): () -> ()
        return function(): ()
          if registry[owner] == created then
            registry[owner] = nil
          end
          table.clear(created.ids)
        end
      end)
    end)
    if not ok then
      if registry[owner] == created then
        registry[owner] = nil
      end
      error(failure, 0)
    end
    entry = created
  end
  assert(not entry.ids[id], 'ui: duplicate control id ' .. id)
  local reservation: Reservation
  reservation = {
    identity = entry.identity,
    release = function(): ()
      if entry.ids[id] == reservation then
        entry.ids[id] = nil
      end
    end,
  }
  entry.ids[id] = reservation
  return reservation
end

return owners

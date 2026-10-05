-- Live plugin owners reserve ids across panels and expose only opaque identity tokens.

local registry = {}

function registry.new(context)
  local owners = {}
  local service = {}
  function service.claim(owner, id, control)
    context:checkOwner(owner)
    local entry = owners[owner]
    if not entry then
      entry = { identity = table.freeze { kind = 'ui-owner' }, ids = {} }
      context:acquire(owner, function()
        owners[owner] = entry
        return function()
          if owners[owner] == entry then
            owners[owner] = nil
          end
        end
      end)
    end
    assert(entry.ids[id] == nil, 'ui substitute: duplicate control id for this owner: ' .. id)
    entry.ids[id] = control
    return entry.identity,
      function()
        if entry.ids[id] == control then
          entry.ids[id] = nil
        end
      end
  end
  return service
end

return registry

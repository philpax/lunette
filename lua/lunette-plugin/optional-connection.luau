-- Connects to one optional capability through an independently owned child activation.

local adapter = require '@lunette-plugin/adapter'

local optionalConnection = {}

export type Connection<T> = {
  read service: T,
  read owner: adapter.Owner,
}

type ActiveConnection<T> = {
  read service: T,
  read owner: adapter.Context,
}

function optionalConnection.connect<T>(
  context: adapter.Context,
  name: string,
  capability: adapter.Capability<T>
): () -> Connection<T>?
  local current: ActiveConnection<T>? = nil
  context:child(adapter.define<<{}>> {
    name = name,
    requires = { capability },
    init = function(child: adapter.Context, _config: {}): ()
      local connection: ActiveConnection<T> = table.freeze {
        service = child:require(capability),
        owner = child,
      }
      child:effect(function(): () -> ()
        current = connection
        return function(): ()
          current = nil
        end
      end)
    end,
  })
  return function(): Connection<T>?
    local connection = current
    return if connection and connection.owner:active() then connection else nil
  end
end

return optionalConnection

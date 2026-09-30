local plugin = require '@lunette-plugin'

type Node = {
  read next: Node?,
  read visit: (Node, (Node) -> ()) -> (),
}
type Service = { read root: (Service) -> Node }
type Config = { read count: number }
local capability = plugin.capability('test/recursive-tree', 1, function(value: Service): Service
  return value
end)
local definition = plugin.define(function(config: Config): Config
  return config
end, { tree = capability }, {}, function(context: plugin.Context, config: Config, _provide: plugin.Publisher)
  local tree: Service = context:require(capability)
  local node: Node = tree:root()
  node:visit(function(item: Node)
    if item.next and config.count > 0 then
      item.next:visit(function(_child: Node) end)
    end
  end)
end)
return definition

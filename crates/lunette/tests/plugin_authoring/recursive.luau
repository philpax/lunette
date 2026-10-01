local plugin = require '@lunette-plugin'

type Node = {
  read next: Node?,
  read visit: (Node, (Node) -> ()) -> (),
}
type Service = { read root: (Service) -> Node }
type Config = { read count: number }
local capability = plugin.capability<<Service>> { name = 'test/recursive-tree', schema = 1 }
local definition = plugin.define {
  name = 'recursive',
  requires = { tree = capability },
  init = function(context: plugin.Context, config: Config, _provide: plugin.Publisher)
    local tree: Service = context:require(capability)
    local node: Node = tree:root()
    node:visit(function(item: Node)
      if item.next and config.count > 0 then
        item.next:visit(function(_child: Node) end)
      end
    end)
  end,
}
return definition

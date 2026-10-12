-- Source selection feedback and VR controls attach through a separate module.
local plugin = require '@lunette-plugin'
local selection = require '@lunette-plugins/desktop/backdrop/selection'

local sourceControls = {}
type Renderer = { read enabled: () -> boolean, read setEnabled: (boolean) -> () }

function sourceControls.attach(_context: plugin.Context, _choice: selection.State, _renderer: Renderer): () end

return sourceControls

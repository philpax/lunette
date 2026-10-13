-- Attaches source selection feedback and VR controls independently of the environment.
local plugin = require '@lunette-plugin'
local selection = require '@lunette-plugins/desktop/backdrop/selection'
local attention = require '@lunette-plugins/desktop/backdrop/attention'
local controls = require '@lunette-plugins/desktop/backdrop/controls'

local sourceControls = {}

function sourceControls.attach(context: plugin.Context, choice: selection.State, renderer: controls.Renderer): ()
  attention.attach(context, choice)
  controls.attach(context, choice, renderer)
end

return sourceControls

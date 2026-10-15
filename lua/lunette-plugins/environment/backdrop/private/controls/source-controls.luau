-- Attaches source selection feedback and VR controls independently of the environment.
local plugin = require '@lunette-plugin'
local selection = require '../selection/selection'
local attention = require '../selection/attention'
local controls = require './controls'

local sourceControls = {}

function sourceControls.attach(context: plugin.Context, choice: selection.State, renderer: controls.Renderer): ()
  attention.attach(context, choice)
  controls.attach(context, choice, renderer)
end

return sourceControls

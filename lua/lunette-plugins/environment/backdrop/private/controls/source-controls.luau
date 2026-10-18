-- Attaches source selection feedback and VR controls independently of the environment.
local plugin = require '@lunette-plugin'
local selection = require '../selection/selection'
local attention = require '../selection/attention'
local controls = require './controls'

local sourceControls = {}

function sourceControls.attach(
  context: plugin.Context,
  choice: selection.State,
  renderer: controls.Renderer,
  view: controls.View
): ()
  attention.attach(context, choice)
  controls.attach(context, choice, renderer, view)
end

return sourceControls

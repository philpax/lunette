-- The default desktop explicitly selects replaceable providers and independent consumers.
local plugin = require '@lunette-plugin'

local frame = require '@lunette-plugins/frame'
local surfaces = require '@lunette-plugins/surfaces'
local panels = require '@lunette-plugins/panels'
local interaction = require '@lunette-plugins/interaction'
local laser = require '@lunette-plugins/laser'
local keyboard = require '@lunette-plugins/keyboard'
local tags = require '@lunette-plugins/tags'
local rules = require '@lunette-plugins/rules'
local adoption = require '@lunette-plugins/adoption'
local arc = require '@lunette-plugins/layout/arc'
local errorDisplay = require '@lunette-plugins/error-display'

local base = require './desktop/base'
local pointing = require './desktop/pointing'
local input = require './desktop/input'
local wristKeyboard = require './desktop/keyboard'
local errors = require './desktop/errors'
local policy = require './desktop/policy'

-- Source reload retains globals, so it must not open another demonstration terminal.
_G.lunetteDemonstrationSpawned = _G.lunetteDemonstrationSpawned or false
local runtime: plugin.Runtime? = nil

-- LÖVR's callbacks are bound before the runtime exists: lovr.load creates it,
-- and lovr.quit runs the quit handlers and then closes it.
frame.install {
  start = function(): ()
    if runtime then
      return
    end
    local graph = plugin.runtime()
    runtime = graph
    graph:use(frame.definition, {}):enable()
    graph:use(surfaces, {}):enable()
    graph:use(panels, {}):enable()
    graph:use(interaction, {}):enable()
    graph:use(laser, {}):enable()
    graph:use(keyboard, {}):enable()
    graph:use(tags, {}):enable()
    graph:use(rules, {}):enable()
    graph:use(adoption, {}):enable()
    graph:use(arc, {}):enable()
    graph:use(errorDisplay.definition, {}):enable()
    graph:use(base, {}):enable()
    graph:use(pointing, {}):enable()
    graph:use(input, {}):enable()
    graph:use(wristKeyboard, {}):enable()
    graph:use(errors, {}):enable()
    graph:use(policy(), {}):enable()
    graph:drain()
  end,
  stop = function(): ()
    local graph = runtime
    runtime = nil
    if graph then
      graph:close()
    end
  end,
}

-- A module load error occurs after GPU allocation, before the runner receives a suite.

local render = require './support/render'
local texture, pass, shader = render.baseline()
_G.graphicsFailureObjects = { texture, pass, shader }
package.loaded.graphicsFailureObjects = _G.graphicsFailureObjects
error 'deliberate module load failure'

local testing = require '@testing'
local expect = testing.expect
local panelsContract = require '@lunette-contracts/panels'
local surfacesContract = require '@lunette-contracts/surfaces'
local interactionContract = require '@lunette-contracts/interaction'
local dropsContract = require '@lunette-contracts/drops'

local test = testing.suite()

local TOLERANCE = 1e-5

local function start()
  local env = {}
  env.session = testing.boot {
    'frame',
    'surfaces',
    'theme',
    'panels',
    'drops',
    'focus',
    'ui',
    'interaction',
    'desktop/render',
    'desktop/decorations',
  }
  env.native = env.session.native
  env.panels = env.session:observe(panelsContract.capability)
  env.surfaces = env.session:observe(surfacesContract.capability)
  env.window = env.native.newWindow(1)
  env.panel = env.panels.service:fromWindow(env.panels.context, env.window, {})
  return env
end

local function offered(env)
  local bar, itself
  for _, surface in ipairs(env.surfaces.service:all()) do
    if surface == env.panel then
      itself = surface
    elseif surface.kind == 'window' and surface.source == env.window then
      bar = surface
    end
  end
  return bar, itself
end

test('the bar is offered beside the panel and sits above it', function()
  local env = start()
  local bar, itself = offered(env)
  expect.truthy(itself, 'the panel is offered')
  expect.truthy(bar, 'its bar is offered')
  local px, py, pz = env.panel.pose:getPosition()
  local bx, by, bz = bar.pose:getPosition()
  expect.near(bx, px, TOLERANCE, 'the bar, x')
  expect.near(bz, pz, TOLERANCE, 'the bar, z')
  expect.truthy(by > py + env.panel.height / 2, 'the bar sits above the top edge of the panel')
  env.session:close()
end)

test("grabbing the bar moves the panel, and the drop announced is the panel's", function()
  local env = start()
  local drops = env.session:observe(dropsContract.capability)
  local dropped = {}
  drops.service:onDropped(drops.context, {
    run = function(drop)
      dropped[#dropped + 1] = drop
    end,
  })
  local interaction = env.session:observe(interactionContract.capability)
  local pointer = interaction.service:newPointer(interaction.context)
  local bar = offered(env)
  local px, py, pz = env.panel.pose:getPosition()

  expect.truthy(pointer:beginGrab(bar, lovr.math.newMat4():translate(0, 1.5, 0)), 'the grab of the bar')
  pointer:dragTo(lovr.math.newMat4():translate(1, 1.5, 0))
  local x, y, z = env.panel.pose:getPosition()
  expect.near(x, px + 1, TOLERANCE, 'the panel follows the hand, x')
  expect.near(y, py, TOLERANCE, 'the panel follows the hand, y')
  expect.near(z, pz, TOLERANCE, 'the panel follows the hand, z')

  expect.truthy(pointer:endGrab(), 'the end of the grab')
  expect.equal(#dropped, 1, 'the drops announced')
  expect.equal(env.panels.service:forSource(dropped[1].surface.source), env.panel, 'the panel the drop names')
  pointer:destroy()
  env.session:close()
end)

test('a hidden panel and its bar are not offered until the panel is shown again', function()
  local env = start()
  local hiding = env.panel:setHidden(env.panels.context, { hidden = true })
  local bar, itself = offered(env)
  expect.equal(bar, nil, 'the bar of a hidden panel')
  expect.equal(itself, nil, 'a hidden panel')
  hiding:dispose()
  bar, itself = offered(env)
  expect.truthy(bar and itself, 'a shown panel and its bar')
  env.session:close()
end)

test("a removed panel's bar is dead and no longer offered", function()
  local env = start()
  local bar = offered(env)
  env.panel:destroy(env.panels.context)
  expect.truthy(bar.dead, 'the bar of a removed panel')
  expect.equal(#env.surfaces.service:all(), 0, 'the surfaces offered after the panel is removed')
  env.session:close()
end)

return test

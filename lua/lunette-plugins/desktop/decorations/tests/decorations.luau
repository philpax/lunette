local testing = require '@testing'
local expect = testing.expect
local panelsContract = require '@lunette-contracts/panels'
local surfacesContract = require '@lunette-contracts/surfaces'
local interactionContract = require '@lunette-contracts/interaction'
local dropsContract = require '@lunette-contracts/drops'

local test = testing.suite()

local TOLERANCE = 1e-5
local OUTLINE_COLOR = { 0.71, 0.19, 0.37, 1 }

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
    {
      id = 'desktop/decorations',
      definition = require '@lunette-plugins/desktop/decorations',
      config = { style = { margin = 0.03, borderColor = OUTLINE_COLOR } },
    },
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

local function registration(env, kind, operation)
  for _, entry in env.panels.service:inspect().registrations do
    if entry.kind == kind and entry.source == operation and entry.details.sourceId == env.window.id then
      return entry
    end
  end
  return nil
end

local function drawnOutline(env)
  env.native.events.draw = {}
  env.session:draw()
  local found
  local count = 0
  for _, call in env.native.events.draw do
    local color = call.state.setColor
    if
      call[1] == 'draw'
      and color
      and color[1] == OUTLINE_COLOR[1]
      and color[2] == OUTLINE_COLOR[2]
      and color[3] == OUTLINE_COLOR[3]
      and color[4] == OUTLINE_COLOR[4]
    then
      found = call[2]
      count += 1
    end
  end
  expect.equal(count, 1, 'one target-owned outline is drawn with chrome disabled')
  return assert(found)
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
  local _, headerBottom = lovr.math.newMat4(bar.pose):translate(0, -bar.height / 2, 0):getPosition()
  local _, bodyTop = lovr.math.newMat4(env.panel.pose):translate(0, env.panel.height / 2, 0):getPosition()
  expect.equal(headerBottom, bodyTop, 'the header and body meet with zero seam')
  expect.equal(bar.width, env.panel.width, 'the header inner width matches the body')
  expect.falsy(env.panel.chrome, 'the target keeps ordinary chrome disabled')
  local attached = assert(registration(env, 'membership', 'panels.attachFrame'))
  expect.truthy(attached.live and attached.details.joined, 'the offered header has a live joined attachment')
  expect.equal(attached.details.headerHeight, bar.height, 'the attachment uses the offered header height')
  local outline = drawnOutline(env)
  expect.falsy(outline.released, 'the attached target retains its outline mesh')
  local target = assert(registration(env, 'panel', 'panels.fromWindow')).details
  expect.truthy(
    target.frameAttached and target.frameJoined and target.outlineMesh,
    'inspection records the delegated outline'
  )
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
  expect.equal(registration(env, 'membership', 'panels.attachFrame'), nil, 'a hidden header releases its attachment')
  hiding:dispose()
  bar, itself = offered(env)
  expect.truthy(bar and itself, 'a shown panel and its bar')
  local attached = assert(registration(env, 'membership', 'panels.attachFrame'))
  expect.truthy(attached.live and attached.details.joined, 'showing restores the joined attachment')
  local _, headerBottom = lovr.math.newMat4(bar.pose):translate(0, -bar.height / 2, 0):getPosition()
  local _, bodyTop = lovr.math.newMat4(env.panel.pose):translate(0, env.panel.height / 2, 0):getPosition()
  expect.equal(headerBottom, bodyTop, 'the restored header has zero seam')
  drawnOutline(env)
  env.session:close()
end)

test("a removed panel's bar is dead and no longer offered", function()
  local env = start()
  local bar = offered(env)
  local outline = drawnOutline(env)
  expect.truthy(registration(env, 'membership', 'panels.attachFrame'), 'the removed target starts with an attachment')
  env.panel:destroy(env.panels.context)
  expect.truthy(bar.dead, 'the bar of a removed panel')
  expect.equal(#env.surfaces.service:all(), 0, 'the surfaces offered after the panel is removed')
  expect.truthy(outline.released, 'target teardown releases the attached outline mesh')
  local releases = 0
  for _, mesh in env.native.events.render.meshReleases do
    if mesh == outline then
      releases += 1
    end
  end
  expect.equal(releases, 1, 'the attached outline mesh is released once')
  expect.equal(registration(env, 'membership', 'panels.attachFrame'), nil, 'target teardown removes its attachment')
  expect.equal(registration(env, 'panel', 'panels.fromWindow'), nil, 'target teardown removes its inspection record')
  env.session:close()
end)

return test

local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local surfaces = require '@lunette-contracts/surfaces'
local keyboard = require '@lunette-contracts/keyboard'
local frame = require '@lunette-contracts/frame'
local quad = require '@lunette-contracts/quad'
local vrUi = require '@testing/vr-ui'

local test = testing.suite()

local function panel(fixture, options)
  local state = { presses = {}, releases = {}, hovers = {}, generation = 0 }
  state.instance = fixture.session:use(plugin.define {
    name = 'testing/vr-panel',
    requires = { surfaces = surfaces.capability, frame = frame.capability },
    init = function(context)
      state.owner = context
      state.generation += 1
      local target = {
        dead = false,
        grabbable = false,
        pose = lovr.math.newMat4():translate(0, 1.5, -2):rotate(0.2, 0, 1, 0),
        width = 2,
        height = 1,
        pixelWidth = 200,
        pixelHeight = 100,
      }
      function target:raycast(origin, direction)
        return quad.hit(self, origin, direction)
      end
      function target:onHover(x, y, pointer)
        state.hovers[pointer] = { x, y }
      end
      function target:onPress(x, y, pointer)
        state.presses[#state.presses + 1] = { pointer = pointer, x = x, y = y }
        if options and options.fail then
          error 'vr fixture surface callback failure'
        end
      end
      function target:onRelease(pointer)
        state.releases[#state.releases + 1] = pointer
      end
      context:effect(function()
        return function()
          target.dead = true
        end
      end)
      context:require(surfaces.capability):offer(context, {
        name = 'vr-fixture-panel',
        list = function()
          return { target }
        end,
      })
      context:require(frame.capability):onDraw(context, {
        phase = 'scene',
        run = function(pass)
          pass:plane(lovr.math.newMat4(target.pose):scale(target.width, target.height, 1))
        end,
      })
      state.target = target
    end,
  })
  return state
end

local function geometry(state)
  local target = state.target
  return {
    name = 'dynamic-panel',
    generation = state.generation,
    revision = state.revision or 1,
    pose = lovr.math.newMat4(target.pose),
    width = target.width,
    height = target.height,
    logicalWidth = target.pixelWidth,
    logicalHeight = target.pixelHeight,
    visible = not target.dead,
    controls = state.controls or {},
  }
end

local function control(id, x)
  return { id = id, kind = 'button', enabled = true, bounds = { x = x, y = 20, width = 20, height = 20 } }
end

test('the VR UI fixture drives real pointers and records output', function()
  local fixture = vrUi.boot()
  local state = panel(fixture)
  fixture:aim(geometry(state), 25, 30, 'left')
  fixture:aim(geometry(state), 170, 70, 'right')
  fixture:step()
  fixture:button('left', 'trigger', true)
  fixture:button('right', 'trigger', true)
  fixture:step()
  expect.equal(#state.presses, 2, 'two real pointers press the offered surface')
  expect.truthy(state.presses[1].pointer ~= state.presses[2].pointer, 'the pointers have independent identities')
  expect.near(state.presses[1].x, 25, 0.001, 'the transformed left hit')
  expect.near(state.presses[2].x, 170, 0.001, 'the transformed right hit')
  fixture:button('left', 'trigger', false)
  fixture:step()
  expect.equal(#state.releases, 1, 'the right hand remains held')
  fixture:tracked('right', false)
  fixture:step()
  expect.equal(#state.releases, 2, 'tracking loss reaches the actual withdrawal path')
  fixture:draw()
  local planes = fixture:drawCalls 'plane'
  expect.truthy(#planes > 0, 'the real frame draw is recorded')
  local inverse = lovr.math.newMat4(state.target.pose):invert()
  local left, bottom = inverse:mul(planes[1].points[1].x, planes[1].points[1].y, planes[1].points[1].z)
  local right, top = inverse:mul(planes[1].points[3].x, planes[1].points[3].y, planes[1].points[3].z)
  expect.near(math.abs(right - left), state.target.width, 0.001, 'the draw width equals the offered hit width')
  expect.near(math.abs(top - bottom), state.target.height, 0.001, 'the draw height equals the offered hit height')
  expect.equal(#fixture:nativeCalls(), 0, 'the Lua surface sends no native input')
  local observed = fixture.session:observe(keyboard.capability)
  local board = observed.service:new(observed.context)
  expect.equal(fixture:keyboardCount(), 1, 'an actual keyboard registration is counted')
  board:destroy()
  expect.equal(fixture:keyboardCount(), 0, 'a destroyed keyboard is not counted')
  fixture:close()
end)

test('the VR UI fixture detects cancellation and render overflow', function()
  local fixture = vrUi.boot()
  local pointer = {}
  fixture:recordPointer { kind = 'press', pointer = pointer, button = 'left' }
  fixture:recordPointer { kind = 'cancel', pointer = pointer, button = 'left', reason = 'tracking-loss' }
  expect.equal(#fixture:cancellations(), 1, 'cancel is recorded separately from release')
  expect.equal(#fixture:releases(), 0, 'cancel does not count as an activating release')
  local recorder = fixture.native.events.render
  recorder:within({ x = 0, y = 0, width = 10, height = 10 }, function(pass)
    pass:plane(5, 5, 0, 4, 4)
  end)
  expect.raises(function()
    recorder:within({ x = 0, y = 0, width = 10, height = 10 }, function(pass)
      pass:plane(10, 5, 0, 4, 4)
    end)
  end, 'bounds', 'render overflow is diagnosed')
  fixture:close()
end)

test('the VR UI fixture discovers a dynamic control and rediscovers after reload', function()
  local fixture = vrUi.boot()
  local state = panel(fixture)
  state.controls = { control('initial', 20) }
  local publicPanel = {
    describe = function()
      return geometry(state)
    end,
  }
  local service = {
    panels = function()
      return { publicPanel }
    end,
  }
  expect.raises(function()
    fixture:clickControl(service, 'dynamic-panel', 'late')
  end, 'control', 'a missing control is not guessed')
  state.controls[#state.controls + 1] = control('late', 70)
  state.revision = 2
  fixture:clickControl(service, 'dynamic-panel', 'late')
  expect.near(state.presses[1].x, 80, 0.001, 'discovery finds the dynamic bounds')
  local previous = state.target
  state.controls = { control('late', 140) }
  state.instance:reload {}
  expect.truthy(previous.dead, 'the old generation is dead')
  fixture:clickControl(service, 'dynamic-panel', 'late')
  expect.near(state.presses[2].x, 150, 0.001, 'a new query finds the replacement geometry')
  fixture:close()
end)

test('the VR UI fixture requeries control geometry after the preparatory update', function()
  local fixture = vrUi.boot()
  local state = panel(fixture)
  state.controls = { control('moving', 20) }
  local service = {
    panels = function()
      return {
        {
          describe = function()
            return geometry(state)
          end,
        },
      }
    end,
  }
  state.owner:require(frame.capability):onUpdate(state.owner, {
    phase = 'scene',
    run = function()
      state.controls = { control('moving', 140) }
      state.revision = 2
    end,
  })
  fixture:clickControl(service, 'dynamic-panel', 'moving')
  expect.near(state.presses[1].x, 150, 0.001, 'the press uses geometry produced by the latest update')
  fixture:close()
end)

test('the VR UI fixture rejects a replacement generation during a gesture', function()
  local fixture = vrUi.boot()
  local state = panel(fixture)
  state.controls = { control('replaced', 20) }
  local service = {
    panels = function()
      return {
        {
          describe = function()
            return geometry(state)
          end,
        },
      }
    end,
  }
  local press = state.target.onPress
  state.target.onPress = function(self, x, y, pointer)
    press(self, x, y, pointer)
    state.instance:reload {}
  end
  expect.raises(function()
    fixture:clickControl(service, 'dynamic-panel', 'replaced')
  end, 'stale gesture', 'the fixture does not continue a gesture in a replacement generation')
  expect.falsy(lovr.headset.isTracked 'hand/right/point', 'stale gesture withdraws the real pointer')
  expect.falsy(lovr.headset.isDown('hand/right', 'trigger'), 'the held button is cleared')
  fixture:close()
end)

test('the VR UI fixture keeps head tracking independent of the controller hands', function()
  local fixture = vrUi.boot()
  fixture:tracked('right', false)
  fixture:pose('right', lovr.math.newMat4():translate(2, 3, -4))
  expect.truthy(lovr.headset.isTracked 'head', 'losing a hand does not lose the head')
  local x, y, z = lovr.headset.getPosition 'head'
  expect.equal(x, 0, 'the head does not follow the hand x position')
  expect.equal(y, 1.5, 'the head height')
  expect.equal(z, 0, 'the head does not follow the hand z position')
  fixture:close()
end)

test('the VR UI fixture records native pointer delivery through an offered surface', function()
  local fixture = vrUi.boot()
  local state = panel(fixture)
  local window = fixture.native.newWindow(17)
  state.target.sink = function()
    return window.sink
  end
  fixture:aim(geometry(state), 80, 50, 'right')
  fixture:step()
  fixture:button('right', 'trigger', true)
  fixture:step()
  fixture:axis('right', 0.5, 0.75)
  fixture:step()
  fixture:button('right', 'trigger', false)
  fixture:step()
  local buttons = fixture:nativeCalls 'button'
  expect.equal(#buttons, 2, 'one native press and release')
  expect.equal(buttons[1][2], 'left', 'the trigger maps to the primary pointer button')
  expect.equal(buttons[1][3], true, 'the press')
  expect.equal(buttons[2][3], false, 'the release')
  expect.truthy(#fixture:nativeCalls 'pointer' > 0, 'native pointer motion')
  expect.truthy(#fixture:nativeCalls 'scroll' > 0, 'native scaled scroll')
  expect.equal(#state.presses, 0, 'native delivery does not also call the Lua press callback')
  fixture:close()
end)

test('the VR UI fixture scripts axes, target death, and callback errors at real boundaries', function()
  local fixture = vrUi.boot()
  local state = panel(fixture, { fail = true })
  fixture:aim(geometry(state), 50, 50, 'right')
  fixture:axis('right', 0.5, -0.75)
  fixture:step()
  expect.equal(lovr.headset.getAxis('hand/right', 'thumbstick'), 0.5, 'the right controller axis')
  expect.equal(lovr.headset.getAxis('hand/left', 'thumbstick'), 0, 'the left controller axis remains independent')
  fixture:button('right', 'trigger', true)
  fixture:step()
  local reports = fixture.native.events.reported
  expect.equal(#reports, 1, 'the frame reports the surface callback error')
  expect.truthy(reports[1].message:find('vr fixture surface callback failure', 1, true), 'the callback failure context')
  state.target.dead = true
  fixture:button('right', 'trigger', false)
  fixture:step()
  fixture:close()
end)

return test

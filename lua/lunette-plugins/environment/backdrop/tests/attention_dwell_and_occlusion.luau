local testing = require '@testing'
local fixture = require './support/source-controls'
local surfaces = require '@lunette-contracts/surfaces'
local render = require '@testing/render'
local expect = testing.expect
local test = testing.suite()

test('attention_dwell_and_occlusion', function()
  local env = fixture.boot { settings = { sourceMode = 'attention' } }
  local first = env.native.newProcess(7)
  local second = env.native.newProcess(8)
  local panel = fixture.window(env, 11, first)
  local sibling = fixture.window(env, 12, first, 2)
  fixture.window(env, 13, second, -2)
  env.running:step(0.4)
  expect.equal(env.choice.attended, nil, 'dwell is not immediate')
  fixture.aimHead(env, 2)
  env.running:step(0.35)
  expect.equal(env.choice.attended, nil, 'completion waits for next input')
  env.running:step(0)
  expect.equal(env.choice.attended, first, 'two panels of one process share a dwell identity')
  expect.equal(panel.highlighted, false, 'attention does not change the panel highlight')
  expect.equal(sibling.highlighted, false, 'attention does not change sibling highlighting')
  expect.equal(#env.native.events.input, 0, 'attention does not deliver input')

  fixture.aimHead(env, -2)
  env.running:step(0.4)
  local blocking = env.panels:fromMonitor(env.owner, env.native.newMonitor 'fixture-monitor', {
    pose = lovr.math.newMat4():translate(-2, 1.5, -1),
    width = 1,
    height = 0.5,
  })
  env.running:step(0.4)
  blocking:setHidden(env.owner, true)
  env.running:step(0.4)
  env.running:step(0)
  expect.equal(env.choice.attended, first, 'a monitor cancels the incomplete dwell')
  env.running:step(0.35)
  env.running:step(0)
  expect.equal(env.choice.attended, second, 'a full new dwell switches source')

  fixture.aimHead(env, 0)
  env.running:step(0.4)
  local uiOwner = env.running.session:observe(require('@lunette-contracts/ui').capability).context
  local uiBlock = env.ui:newPanel(uiOwner, {
    name = 'testing/occluder',
    pose = lovr.math.newMat4():translate(0, 1.5, -1),
    width = 1,
    height = 0.5,
    logicalWidth = 100,
    logicalHeight = 50,
  })
  env.running:step(1)
  expect.equal(env.choice.attended, second, 'an offered UI surface occludes the window')
  uiBlock:destroy()
  local offered = env.running.session:observe(surfaces.capability).service
  local count = #offered:all()
  env.running:step(0.75)
  env.running:draw()
  expect.equal(#offered:all(), count, 'the dwell badge is not an offered surface')
  env.running:step(0)
  expect.equal(env.choice.attended, first, 'the unoccluded window is selected')
  env.running:close()
end)

for failureAt = 1, 2 do
  test('the attention badge restores the pass when plane ' .. failureAt .. ' raises', function()
    local env = fixture.boot { settings = { sourceMode = 'attention' } }
    fixture.window(env, 70 + failureAt, env.native.newProcess(70 + failureAt))
    -- The untracked wrist hides the wrist menu, whose text the fake renderer cannot draw, so the frame reports only
    -- the injected failure.
    env.running:tracked('left', false)
    env.running:step(0.4)
    local pass = env.native.events.pass
    local recorder = env.native.events.render
    pass:setShader 'normal'
    pass:setColor(0.1, 0.2, 0.3, 0.4)
    pass:setDepthTest 'lequal'
    pass:setDepthWrite(true)
    pass:translate(2, 3, 4)
    pass:push 'state'
    pass:push 'transform'
    local checkpoint = recorder:checkpoint()
    local originalPlane = pass.plane
    local planes = 0
    function pass.plane(self: render.Pass, ...: any): ()
      originalPlane(self, ...)
      local color = recorder._state.setColor
      if color and ((color[1] == 0.75 and color[2] == 0.85) or (color[1] == 0.1 and color[2] == 0.3)) then
        planes += 1
        if planes == failureAt then
          error('injected attention badge plane failure', 0)
        end
      end
    end
    env.running:draw()
    local reports = env.native.events.reported
    expect.equal(#reports, 1, 'the frame boundary reports the badge draw failure')
    expect.truthy(
      string.find(reports[1].message, 'injected attention badge plane failure', 1, true),
      'the error propagates'
    )
    expect.equal(planes, failureAt, 'the intended badge plane raises')
    recorder:assertRestored(checkpoint)
    pass:pop 'transform'
    pass:pop 'state'
    env.running:close()
  end)
end

return test

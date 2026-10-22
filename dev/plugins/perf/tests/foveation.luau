local testing = require '@testing'
local foveation = require '../foveation'
local expect = testing.expect
local test = testing.suite()

type Fake = {
  level: foveation.Level,
  dynamic: boolean,
  overlay: boolean,
  supported: boolean,
  saved: { { [string]: unknown } },
  cleanups: { () -> () },
}

-- A headset that refuses foveation and the overlay when unsupported, as LÖVR's does, and a context that records saves
-- and runs its effects' cleanups when it ends.
local function fakes(supported: boolean): (any, foveation.Headset, Fake)
  local fake: Fake = {
    level = 'medium',
    dynamic = true,
    overlay = false,
    supported = supported,
    saved = {},
    cleanups = {},
  }
  local headset: foveation.Headset = {
    getFoveation = function(): (foveation.Level, boolean)
      return fake.level, fake.dynamic
    end,
    setFoveation = function(level: foveation.Level, dynamic: boolean): boolean
      if level ~= 'none' and not fake.supported then
        return false
      end
      fake.level, fake.dynamic = level, dynamic
      return true
    end,
    getFoveationOverlay = function(): boolean
      return fake.overlay
    end,
    setFoveationOverlay = function(enabled: boolean): boolean
      if enabled and not fake.supported then
        return false
      end
      fake.overlay = enabled
      return true
    end,
  }
  local context = {
    effect = function(_self: any, acquire: () -> () -> ()): any
      table.insert(fake.cleanups, acquire())
      return {}
    end,
    save = function(_self: any, changes: { [string]: unknown }): boolean
      table.insert(fake.saved, changes)
      return true
    end,
  }
  return context, headset, fake
end

local function finish(fake: Fake): ()
  for index = #fake.cleanups, 1, -1 do
    fake.cleanups[index]()
  end
end

test('attaching applies the saved settings without saving them again', function()
  local context, headset, fake = fakes(true)
  local controller = foveation.attach(context, headset, { level = 'low', overlay = true })
  expect.equal(fake.level, 'low')
  expect.equal(fake.dynamic, false, 'the level is fixed')
  expect.equal(fake.overlay, true)
  expect.equal(#fake.saved, 0)
  local status = controller:status()
  expect.equal(status.levelUnavailable, false)
  expect.equal(status.overlayUnavailable, false)
end)

test('changes apply and save, and an unchanged value saves nothing', function()
  local context, headset, fake = fakes(true)
  local controller = foveation.attach(context, headset, { level = 'low', overlay = false })
  expect.equal(controller:setLevel('high').level, 'high')
  expect.equal(fake.level, 'high')
  controller:setLevel 'high'
  controller:setOverlay(true)
  expect.equal(#fake.saved, 2)
  expect.equal(fake.saved[1].foveation, 'high')
  expect.equal(fake.saved[2].overlay, true)
  controller:setLevel 'none'
  expect.equal(fake.level, 'none', "'none' disables foveation")
end)

test('an unsupported headset reports a refused level and overlay, and disabling keeps the report', function()
  local context, headset, fake = fakes(false)
  local controller = foveation.attach(context, headset, { level = 'none', overlay = false })
  local status = controller:status()
  expect.equal(status.levelUnavailable, false, "disabling succeeds, so 'none' reports nothing")
  expect.equal(status.overlayUnavailable, false, 'disabling the overlay reports nothing')
  status = controller:setLevel 'low'
  expect.equal(status.levelUnavailable, true, 'a refused level is reported')
  expect.equal(status.level, 'low', 'the requested level is kept')
  expect.equal(fake.saved[1].foveation, 'low', 'the request is saved for a headset that supports it')
  status = controller:setLevel 'none'
  expect.equal(status.levelUnavailable, true, "'none' does not prove support")
  status = controller:setOverlay(true)
  expect.equal(status.overlayUnavailable, true)
  status = controller:setOverlay(false)
  expect.equal(status.overlayUnavailable, true, 'disabling the overlay does not prove support')
end)

test('a support report clears when the headset accepts a later request', function()
  local context, headset, fake = fakes(false)
  local controller = foveation.attach(context, headset, { level = 'low', overlay = true })
  expect.equal(controller:status().levelUnavailable, true)
  fake.supported = true
  local status = controller:setLevel 'medium'
  expect.equal(status.levelUnavailable, false)
end)

test('the end of the context restores the previous level, dynamic mode, and overlay', function()
  local context, headset, fake = fakes(true)
  local controller = foveation.attach(context, headset, { level = 'high', overlay = true })
  controller:setLevel 'low'
  finish(fake)
  expect.equal(fake.level, 'medium')
  expect.equal(fake.dynamic, true)
  expect.equal(fake.overlay, false)
end)

return test

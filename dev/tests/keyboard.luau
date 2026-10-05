-- The development configuration loads the example provider, whose keyboards use the desktop wrist button.
local testing = require '@testing'
local expect = testing.expect
local desktop = require '@lunette-desktop'
local surfacesContract = require '@lunette-contracts/surfaces'

local test = testing.suite()

test('the development wrist button shows the rounded example and draws every key face', function()
  local native = testing.native()
  local events = native.events
  testing.host.useConfiguration 'dev'
  local configuration
  local run = desktop.run
  desktop.run = function(options)
    configuration = options
    run(options)
  end
  require 'main'
  desktop.run = run
  expect.truthy(package.loaded['examples/keyboard/rounded'], 'the development configuration loads the example')
  lovr.load()
  lovr.update(0.016)
  expect.equal(lovr.draw(events.pass), false, 'development draw does not veto')
  expect.equal(lovr.quit(), false, 'development quit does not veto')

  local rounded = require '../examples/keyboard/rounded'
  local entries = desktop.compose(configuration)
  for _, entry in ipairs(entries) do
    if entry.id == 'keyboard' then
      expect.equal(entry.definition, rounded, 'the configuration replaces the keyboard provider')
    end
  end
  local session = testing.boot(entries, { native = native })
  local surfaces = session:observe(surfacesContract.capability)
  local function wrist()
    for _, candidate in ipairs(surfaces.service:all()) do
      if candidate.grabbable == false and candidate.width == 0.115 then
        return candidate
      end
    end
    error 'the desktop wrist button is absent'
  end
  local function keyboardCount()
    local count = 0
    for _, candidate in ipairs(surfaces.service:all()) do
      if candidate.pressKey then
        count += 1
      end
    end
    return count
  end
  local function board()
    for _, candidate in ipairs(surfaces.service:all()) do
      if candidate.pressKey then
        return candidate
      end
    end
    error 'the shown keyboard is absent'
  end
  local function toggle()
    wrist():onPointer {
      kind = 'press',
      pointer = {
        vibrate = function()
          return true
        end,
      },
      button = 'left',
      x = 0.5,
      y = 0.5,
      captured = true,
      inside = true,
    }
  end
  local function drawKeyboard()
    session:update()
    events.draw = {}
    expect.equal(session:draw(), false, 'draw does not veto')
    local faces = 0
    local legends = {}
    for _, call in ipairs(events.draw) do
      if call[1] == 'roundrect' then
        faces += 1
      elseif call[1] == 'text' then
        legends[call[2]] = true
      end
    end
    local target = board()
    expect.truthy(target.visible, 'the wrist button shows the keyboard')
    expect.truthy(#target:keys() > 0, 'the keyboard has keys')
    expect.equal(faces, #target:keys(), 'the example draws one rounded face per key')
    for _, key in ipairs(target:keys()) do
      expect.truthy(legends[key.legend], 'the default legend is preserved: ' .. key.legend)
    end
    return target
  end

  expect.equal(keyboardCount(), 0, 'no keyboard surface is offered before showing it')
  toggle()
  local first = drawKeyboard()
  expect.equal(keyboardCount(), 1, 'one keyboard surface is offered while visible')
  toggle()
  expect.equal(keyboardCount(), 0, 'hiding removes the keyboard from the surface service')
  events.draw = {}
  session:draw()
  for _, call in ipairs(events.draw) do
    expect.truthy(call[1] ~= 'roundrect', 'hidden keyboards draw no rounded faces')
  end
  toggle()
  expect.equal(board(), first, 'showing again reuses the same keyboard')
  session.instances.keyboard:reload()
  expect.truthy(first.dead, 'provider reload destroys the old keyboard')
  expect.equal(keyboardCount(), 0, 'provider reload removes the old keyboard surface')
  toggle()
  local replacement = drawKeyboard()
  expect.truthy(replacement ~= first, 'provider reload creates a replacement keyboard')
  expect.equal(keyboardCount(), 1, 'only the replacement keyboard surface is offered')
  session:close()
  expect.truthy(replacement.dead, 'closing the session destroys the replacement keyboard')
end)

return test

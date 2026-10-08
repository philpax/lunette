-- The development wrist menu controls the rounded example through real controller input.
local testing = require '@testing'
local expect = testing.expect
local vrUi = require '@testing/vr-ui'
local observer = require './support/development-observer'

local test = testing.suite()

local function services()
  return assert(_G.devTestServices, 'the development configuration observer is active')
end

local function keyboardCount()
  local count = 0
  for _, candidate in ipairs(services().surfaces:all()) do
    if candidate.pressKey then
      count += 1
    end
  end
  return count
end

local function board()
  for _, candidate in ipairs(services().surfaces:all()) do
    if candidate.pressKey then
      return candidate
    end
  end
  error 'the shown keyboard is absent'
end

local function keyboardConfig()
  for _, entry in ipairs(services().composition:entries()) do
    if entry.id == 'keyboard' then
      expect.equal(entry.name, 'rounded-keyboard', 'the actual development provider is active')
      local metadata = entry.schema
      while metadata.kind == 'default' or metadata.kind == 'optional' or metadata.kind == 'refine' do
        metadata = metadata.child
      end
      return (entry.config and entry.config.rows) or metadata.fields.rows.value
    end
  end
  error 'the configured keyboard provider is absent'
end

local function drawKeyboard(fixture)
  local current = services()
  local seat = fixture.native.events.seats[#fixture.native.events.seats]
  local focused = current.focus:register(current.owner, {
    kind = 'local',
    keymapSeat = seat,
    wantsKeyboard = false,
    receiver = {
      key = function()
        return false
      end,
      text = function()
        return false
      end,
    },
  })
  expect.truthy(focused:focus(), 'the public focus target supplies the keyboard keymap')
  fixture:step()
  fixture.native.events.draw = {}
  expect.equal(fixture:draw(), false, 'draw does not veto')
  local faces, legends = 0, {}
  for _, call in ipairs(fixture.native.events.draw) do
    if call[1] == 'roundrect' then
      faces += 1
    elseif call[1] == 'text' then
      legends[call[2]] = true
    end
  end
  local target, rows = board(), keyboardConfig()
  local localFromWorld = lovr.math.newMat4(target.pose):invert()
  local faceDepth
  for _, call in ipairs(fixture.native.events.draw) do
    if call[1] == 'roundrect' then
      local x, y, z = call[2]:mul(0, 0, 0.5, 1)
      faceDepth = select(3, localFromWorld:mul(x, y, z))
      expect.near(faceDepth, 0, 1e-5, 'the rounded key front lies on the interaction plane')
    elseif call[1] == 'text' and faceDepth then
      local x, y, z = call[3]:getPosition()
      local depth = select(3, localFromWorld:mul(x, y, z))
      expect.truthy(depth > faceDepth + 1e-5, 'the legend is separated from the rounded key front')
      faceDepth = nil
    end
  end
  expect.truthy(target.visible, 'the menu shows the keyboard')
  local keyCount = 0
  for _, row in ipairs(rows) do
    for _, key in ipairs(row) do
      if key.code or key.action then
        keyCount += 1
        local legend = key.label
        if not legend and key.code then
          legend = seat:characterFor(key.code, {}) or string.format('0x%x', seat:symbolFor(key.code))
        end
        expect.truthy(legend and legends[legend], 'the default legend is preserved: ' .. tostring(legend))
      end
    end
  end
  expect.truthy(keyCount > 0, 'the keyboard has keys')
  expect.equal(faces, keyCount, 'the example draws one rounded face per key')
  expect.truthy(focused:destroy(), 'the test releases its local focus target')
  return target
end

test('the development wrist menu toggles the rounded keyboard and survives source reload', function()
  local native = testing.native()
  testing.host.useConfiguration 'dev'
  observer.load()
  expect.truthy(package.loaded['examples/keyboard/rounded'], 'the development configuration loads the example')
  lovr.load()
  local fixture = vrUi.attach(native)
  fixture:pose('left', lovr.math.newMat4():translate(0, 1.2, -0.5))
  fixture:tracked('left', true)
  fixture:step()
  expect.equal(keyboardCount(), 0, 'no keyboard surface is offered before showing it')

  local function toggle()
    fixture:step()
    local ui = services().ui
    fixture:clickControl(ui, 'desktop/menu', 'open')
    fixture:clickControl(ui, 'desktop/menu', 'actions', 'right', 'desktop/keyboard/toggle')
    fixture:clickControl(ui, 'desktop/menu', 'close')
  end

  toggle()
  local first = drawKeyboard(fixture)
  expect.equal(keyboardCount(), 1, 'one keyboard surface is offered while visible')
  expect.equal(services().keyboard:inspect().logicalRegistrationCount, 1, 'one keyboard is created')
  toggle()
  expect.equal(keyboardCount(), 0, 'hiding removes the keyboard from the surface service')
  expect.equal(services().keyboard:inspect().logicalRegistrationCount, 1, 'hiding retains the keyboard')
  native.events.draw = {}
  fixture:draw()
  for _, call in ipairs(native.events.draw) do
    expect.truthy(call[1] ~= 'roundrect', 'hidden keyboards draw no rounded faces')
  end
  toggle()
  expect.equal(board(), first, 'showing again reuses the same keyboard')
  testing.host.useConfiguration 'dev/tests/support/vr-reload'
  local previousUi = services().ui
  fixture:clickControl(previousUi, 'desktop/menu', 'open')
  fixture:clickControl(previousUi, 'desktop/menu', 'actions', 'right', 'desktop/reload')
  expect.truthy(first.dead, 'source reload destroys the old keyboard')
  expect.equal(keyboardCount(), 0, 'source reload removes the old keyboard surface')
  expect.equal(services().keyboard:inspect().logicalRegistrationCount, 0, 'source reload starts with no keyboard')
  toggle()
  local replacement = drawKeyboard(fixture)
  expect.truthy(replacement ~= first, 'source reload creates a replacement keyboard')
  expect.equal(keyboardCount(), 1, 'only the replacement keyboard surface is offered')
  expect.equal(lovr.quit(), false, 'development quit does not veto')
  expect.equal(#testing.host.shutdown(), 0, 'the shutdown failures')
  expect.truthy(replacement.dead, 'closing the session destroys the replacement keyboard')
  native.assertResourcesReleased()
end)

return test

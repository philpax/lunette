-- The development wrist menu controls the theme-driven keyboard through real controller input.
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
      expect.equal(entry.name, 'keyboard', 'the theme-driven development provider is active')
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
  local target, rows = board(), keyboardConfig()
  local localFromWorld = lovr.math.newMat4(target.pose):invert()
  local faces, legendCount, legends, meshes = 0, 0, {}, {}
  local faceDepth
  for _, call in ipairs(fixture.native.events.draw) do
    if call[1] == 'draw' then
      local x, y, z = call.transform:getPosition()
      local localX, localY, depth = localFromWorld:mul(x, y, z)
      if math.abs(depth) < 1e-5 and math.abs(localX) < target.width / 2 and math.abs(localY) < target.height / 2 then
        expect.equal(faceDepth, nil, 'each theme key face has its legend')
        local mesh = call[2]
        expect.truthy(#mesh.vertices > 4, 'the selected theme gives key faces rounded mesh geometry')
        expect.truthy(#mesh.indices > 0 and #mesh.indices % 3 == 0, 'the key face has indexed triangles')
        expect.equal(#call.points, #mesh.indices, 'the recorder measures every emitted key-face vertex')
        for _, point in ipairs(call.points) do
          local px, py, pz = localFromWorld:mul(point.x, point.y, point.z)
          expect.near(pz, 0, 1e-5, 'the theme key face lies on the interaction plane')
          expect.truthy(math.abs(px) <= target.width / 2 + 1e-5, 'the key face stays within the keyboard width')
          expect.truthy(math.abs(py) <= target.height / 2 + 1e-5, 'the key face stays within the keyboard height')
        end
        faces += 1
        meshes[mesh] = true
        faceDepth = depth
      end
    elseif call[1] == 'text' and faceDepth then
      local x, y, z = call[3]:getPosition()
      x, y, z = call.transform:mul(x, y, z)
      local depth = select(3, localFromWorld:mul(x, y, z))
      expect.truthy(depth > faceDepth + 1e-5, 'the legend is separated from the theme key face')
      legendCount += 1
      legends[call[2]] = true
      faceDepth = nil
    end
  end
  expect.equal(faceDepth, nil, 'the final theme key face has its legend')
  expect.equal(legendCount, faces, 'every theme key face has one separated legend')
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
  expect.equal(faces, keyCount, 'the theme-driven keyboard draws one mesh face per key')
  expect.truthy(focused:destroy(), 'the test releases its local focus target')
  return target, meshes
end

test('the development wrist menu toggles the theme-driven keyboard and survives source reload', function()
  local native = testing.native()
  testing.host.useConfiguration 'dev'
  observer.load()
  expect.truthy(
    package.loaded['@lunette-plugins/keyboard'],
    'the development configuration loads the keyboard provider'
  )
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
    fixture:clickControl(ui, 'desktop/menu/titlebar', 'close')
  end

  toggle()
  local first, firstMeshes = drawKeyboard(fixture)
  expect.equal(keyboardCount(), 1, 'one keyboard surface is offered while visible')
  expect.equal(services().keyboard:inspect().logicalRegistrationCount, 1, 'one keyboard is created')
  toggle()
  expect.equal(keyboardCount(), 0, 'hiding removes the keyboard from the surface service')
  expect.equal(services().keyboard:inspect().logicalRegistrationCount, 1, 'hiding retains the keyboard')
  native.events.draw = {}
  fixture:draw()
  for _, call in ipairs(native.events.draw) do
    expect.falsy(call[1] == 'draw' and firstMeshes[call[2]], 'hidden keyboards draw no theme key-face meshes')
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

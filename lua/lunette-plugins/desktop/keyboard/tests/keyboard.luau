local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local keyboardModule = require '@lunette-plugins/keyboard'
local keyboardContract = require '@lunette-contracts/keyboard'
local displayContract = require '@lunette-contracts/keyboard-display'
local surfacesContract = require '@lunette-contracts/surfaces'
local definition = require '@lunette-plugins/desktop/keyboard'
local descriptor = require('@lunette-plugins/desktop/keyboard/config').schema

local test = testing.suite()

local function start(config)
  local env = { drawnBy = {} }
  local tracing = keyboardModule.define {
    drawKey = function(pass, key, state, base)
      env.drawnBy[state.keyboard] = (env.drawnBy[state.keyboard] or 0) + 1
      base(pass, key, state)
    end,
  }
  env.session = testing.boot {
    'frame',
    'surfaces',
    'focus',
    'ui',
    { id = 'keyboard', definition = tracing },
    { id = 'desktop/keyboard', definition = definition, config = config },
  }
  env.surfaces = env.session:observe(surfacesContract.capability).service
  env.display = env.session:observe(displayContract.capability).service
  return env
end

local function shownKeyboard(env)
  for _, candidate in ipairs(env.surfaces:all()) do
    if candidate.setLayer then
      return candidate
    end
  end
  return nil
end

local function expectPosition(board, expected, label)
  local position = vector.pack(board.pose:getPosition())
  expect.near(position.x, expected.x, 1e-5, label .. ' x')
  expect.near(position.y, expected.y, 1e-5, label .. ' y')
  expect.near(position.z, expected.z, 1e-5, label .. ' z')
end

local function expectDirection(board, axis, expected, label)
  local direction = vector.pack(board.pose:mul(axis.x, axis.y, axis.z, 0))
  expect.near(direction.x, expected.x, 1e-5, label .. ' x')
  expect.near(direction.y, expected.y, 1e-5, label .. ' y')
  expect.near(direction.z, expected.z, 1e-5, label .. ' z')
end

test('removed wrist fields point raw configuration to settings.menu', function()
  for _, field in ipairs { 'hand', 'size', 'offset', 'haptic' } do
    for _, value in ipairs { false, 'right', 0.2, vector.pack(0.1, 0.2, 0.3), {} } do
      local config = { [field] = value }
      for _, parse in ipairs {
        function()
          return descriptor.parse(config)
        end,
        function()
          return descriptor.resolve(config, descriptor.parse {})
        end,
        function()
          return definition.resolve(config)
        end,
      } do
        local ok, problem = pcall(parse)
        expect.equal(ok, false, 'the removed ' .. field .. ' field is rejected')
        local message = tostring(problem)
        expect.truthy(message:find('wristKeyboard.' .. field, 1, true), 'the removed field: ' .. message)
        expect.truthy(message:find('settings.menu', 1, true), 'the replacement settings: ' .. message)
      end
    end
  end
end)

test('the keyboard provider offers no wrist trigger while hidden or visible', function()
  local env = start {}
  local hiddenCount = #env.surfaces:all()
  local opened = env.display:show()
  local offered = env.surfaces:all()
  local board = shownKeyboard(env)
  local haptics = env.session.native.events.haptics or 0
  env.session:close()
  expect.equal(hiddenCount, 0, 'the hidden display offers no trigger')
  expect.truthy(opened, 'the public display opens')
  expect.equal(#offered, 3, 'the keyboard and shared titlebar surfaces are offered')
  expect.truthy(board, 'the offered surfaces include the keyboard')
  expect.equal(haptics, 0, 'showing does not pulse a controller')
end)

test('a pitched head keeps the keyboard at the configured horizontal distance', function()
  local env = start { placement = { distance = 0.8, drop = 0.25 } }
  for _, pitch in ipairs { -math.pi / 3, 0, math.pi / 3 } do
    lovr.headset.getDirection = function()
      return math.cos(pitch) * 0.6, math.sin(pitch), -math.cos(pitch) * 0.8
    end
    expect.truthy(env.display:show(), 'the public display opens')
    local shown = shownKeyboard(env)
    expect.truthy(shown and shown.visible, 'the keyboard is visible')
    local head = vector.pack(lovr.headset.getPosition 'head')
    expectPosition(shown, head + vector.pack(0.48, -0.25, -0.64), 'the pitched placement')
    env.display:hide()
  end
  env.session:close()
end)

test('a near-vertical head direction places the keyboard along the forward fallback', function()
  local env = start { placement = { distance = 0.8, drop = 0.25 } }
  for _, direction in ipairs { vector.pack(0, 1, 0), vector.pack(0.0001, -1, 0.0001) } do
    lovr.headset.getDirection = function()
      return direction:unpack()
    end
    expect.truthy(env.display:show(), 'the public display opens')
    local shown = shownKeyboard(env)
    local head = vector.pack(lovr.headset.getPosition 'head')
    expectPosition(shown, head + vector.pack(0, -0.25, -0.8), 'the fallback placement')
    expectDirection(shown, vector.pack(1, 0, 0), vector.pack(1, 0, 0), 'the fallback horizontal axis')
    env.display:hide()
  end
  env.session:close()
end)

test('placement applies head yaw before the configured downward tilt', function()
  local env = start { placement = { distance = 0.8, drop = 0.25, tilt = math.pi / 6 } }
  lovr.headset.getDirection = function()
    return 1, -0.2, 0
  end
  expect.truthy(env.display:show(), 'the public display opens')
  local shown = shownKeyboard(env)
  local head = vector.pack(lovr.headset.getPosition 'head')
  expectPosition(shown, head + vector.pack(0.8, -0.25, 0), 'the turned placement')
  expectDirection(shown, vector.pack(1, 0, 0), vector.pack(0, 0, 1), 'the horizontal axis')
  expectDirection(shown, vector.pack(0, 1, 0), vector.pack(0.5, math.sqrt(0.75), 0), 'the tilted vertical axis')
  expectDirection(shown, vector.pack(0, 0, 1), vector.pack(-math.sqrt(0.75), 0.5, 0), 'the tilted normal')
  env.session:close()
end)

test('public visibility operations reuse one board and place it only when shown', function()
  local env = start {}
  expect.equal(shownKeyboard(env), nil, 'the board starts hidden')
  expect.truthy(env.display:show(), 'the initial show succeeds')
  local board = shownKeyboard(env)
  local position = vector.pack(board.pose:getPosition())
  lovr.headset.getPosition = function()
    return 2, 3, 4
  end
  expect.truthy(env.display:show(), 'the repeated show succeeds')
  env.session:update()
  expect.equal(shownKeyboard(env), board, 'a repeated show reuses the board')
  expectPosition(board, position, 'the visible placement does not follow the head')
  expect.truthy(env.display:hide(), 'hide succeeds')
  expect.equal(#env.surfaces:all(), 0, 'hide withdraws the keyboard')
  expect.truthy(env.display:toggle(), 'toggle shows the keyboard')
  expect.equal(shownKeyboard(env), board, 'a later show reuses the board')
  expectPosition(board, vector.pack(2, 2.65, 3.45), 'a later show places from the new head position')
  expect.truthy(env.display:toggle(), 'toggle hides the keyboard')
  expect.equal(board.visible, false, 'toggle leaves the board hidden')
  expect.equal(board.dead, false, 'hiding retains the board')
  expect.truthy(env.display:show(), 'the final show succeeds')
  expect.equal(#env.surfaces:all(), 3, 'the display offers one board and its shared titlebar')
  env.session:close()
  expect.equal(board.dead, true, 'closing destroys the owned board')
  local ok, problem = pcall(function()
    return env.display:show()
  end)
  expect.equal(ok, false, 'the stopped display capability is unavailable')
  expect.truthy(tostring(problem):find('provider activation has ended', 1, true), 'the display activation ended')
end)

test("the provider draws its own keyboard and not another owner's", function()
  local env = start {}
  local other
  env.session:use(plugin.define {
    name = 'other-keyboard',
    requires = { keyboard = keyboardContract.capability },
    init = function(context)
      other = context:require(keyboardContract.capability):new(context)
    end,
  })
  expect.truthy(other.visible, "another owner's keyboard is visible")
  expect.truthy(env.display:show(), 'the public display opens')
  local shown
  for _, candidate in ipairs(env.surfaces:all()) do
    if candidate ~= other and candidate.setLayer then
      shown = candidate
    end
  end
  env.session:update()
  env.session:draw()
  expect.truthy((env.drawnBy[shown] or 0) > 0, 'the display keyboard is drawn')
  expect.equal(env.drawnBy[other], nil, "another owner's keyboard is not drawn by the provider")
  env.session:close()
end)

test('removed wrist settings fail raw provider activation by field and name', function()
  for _, field in ipairs { 'hand', 'size', 'offset', 'haptic' } do
    local env = start { [field] = false }
    local diagnostic = tostring(env.session.instances['desktop/keyboard']:diagnostic())
    local reports = testing.takeReports()
    env.session:close()
    expect.truthy(diagnostic:find('plugin desktop/keyboard: wristKeyboard.' .. field, 1, true), diagnostic)
    expect.truthy(diagnostic:find('settings.menu', 1, true), diagnostic)
    expect.equal(#reports, 1, 'one activation failure is reported')
  end
end)

test('nested placement settings retain defaults and schema metadata omits wrist fields', function()
  local settings = descriptor.parse { placement = { distance = 0.8 } }
  expect.equal(settings.placement.distance, 0.8, 'the configured distance')
  expect.equal(settings.placement.drop, 0.35, 'the default drop')
  expect.equal(settings.placement.tilt, math.pi / 6, 'the default tilt')
  local changed = descriptor.resolve({ placement = { tilt = 0 } }, settings)
  expect.equal(changed.placement.distance, 0.8, 'the base distance is retained')
  expect.equal(changed.placement.drop, 0.35, 'the base drop is retained')
  expect.equal(changed.placement.tilt, 0, 'the configured tilt')
  local input = { placement = { distance = 0.8 } }
  expect.equal(descriptor.input(input), input, 'the input witness accepts placement-only configuration')
  expect.equal(descriptor.output(settings), settings, 'the output witness retains resolved settings')
  local metadata = descriptor.inspect()
  expect.equal(metadata.kind, 'object', 'the descriptor remains an object')
  expect.truthy(metadata.fields.placement, 'the placement metadata remains available')
  for _, field in ipairs { 'hand', 'size', 'offset', 'haptic' } do
    expect.equal(metadata.fields[field], nil, 'the removed ' .. field .. ' metadata')
    expect.equal(settings[field], nil, 'the removed ' .. field .. ' output')
  end
  expect.equal(plugin.definitionSchema(definition).child, metadata, 'the provider retains descriptor metadata')
end)

test('malformed placement fields fail parsing and resolution without changing the base', function()
  local base = descriptor.parse { placement = { distance = 0.8, drop = 0.25, tilt = 0 } }
  for _, config in ipairs {
    { placement = false },
    { placement = { size = 0.2 } },
    { placement = { distance = false } },
    { placement = { drop = 'down' } },
    { placement = { tilt = {} } },
    { placement = { distance = math.huge } },
    { placement = { drop = -math.huge } },
    { placement = { tilt = 0 / 0 } },
  } do
    for _, parse in ipairs {
      function()
        return descriptor.parse(config)
      end,
      function()
        return descriptor.resolve(config, base)
      end,
    } do
      local ok, problem = pcall(parse)
      expect.equal(ok, false, 'the malformed placement is rejected')
      expect.truthy(
        tostring(problem):find('placement', 1, true),
        'the error identifies placement: ' .. tostring(problem)
      )
    end
  end
  expect.equal(base.placement.distance, 0.8, 'the base distance is unchanged')
  expect.equal(base.placement.drop, 0.25, 'the base drop is unchanged')
  expect.equal(base.placement.tilt, 0, 'the base tilt is unchanged')
end)

return test

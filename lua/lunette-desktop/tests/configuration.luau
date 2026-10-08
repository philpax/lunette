-- Desktop entries reject unknown and mistyped options, and configured values reach their services.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local desktop = require '@lunette-desktop'
local panels = require '@lunette-contracts/panels'
local interaction = require '@lunette-contracts/interaction'
local laser = require '@lunette-contracts/laser'
local rules = require '@lunette-contracts/rules'
local adoption = require '@lunette-contracts/adoption'

local test = testing.suite()

local function rejection(patch)
  testing.native()
  local running = plugin.start(desktop.compose { patches = { patch } })
  local instance = running.instances[patch.id]
  expect.equal(instance:state(), 'failed', patch.id)
  local diagnostic = tostring(instance:diagnostic())
  running.runtime:close()
  expect.equal(#testing.takeReports(), 1, 'the failure of ' .. patch.id .. ' is reported')
  return diagnostic
end

test('every entry rejects an option it does not take, naming itself and the option', function()
  for _, entry in ipairs(desktop.entries()) do
    local diagnostic
    if entry.id == 'desktop/manager' then
      local ok, problem = pcall(entry.definition.resolve, { bogus = 1 })
      expect.falsy(ok, 'the manager rejects an undeclared option before activation')
      diagnostic = tostring(problem)
    else
      diagnostic = rejection { id = entry.id, config = { bogus = 1 } }
    end
    expect.truthy(
      diagnostic:find(
        if entry.id == 'theme'
          then 'plugin theme: unknown option bogus; theme takes no options'
          else 'plugin ' .. entry.id .. ': option bogus is not a declared field',
        1,
        true
      ),
      entry.id .. ': ' .. diagnostic
    )
  end
end)

test('pointing rejects hand selection and a shared seat rather than changing its two-hand attachment', function()
  for key, value in pairs { hand = 'right', seat = {} } do
    local diagnostic = rejection { id = 'desktop/pointing', config = { laser = { [key] = value } } }
    local message = 'plugin desktop/pointing: option laser.' .. key .. ' is not a declared field'
    expect.truthy(diagnostic:find(message, 1, true), diagnostic)
  end
end)

test('an option of the wrong type is rejected with its path and what it should be', function()
  for _, case in ipairs {
    {
      patch = { id = 'interaction', config = { focusOnPress = 'yes' } },
      message = 'plugin interaction: option focusOnPress is a boolean, not a string',
    },
    {
      patch = { id = 'pacing', config = { tuning = { background = 0 } } },
      message = 'plugin pacing: option tuning.background is a rate in hertz above zero, not 0',
    },
    {
      patch = { id = 'desktop/monitors', config = { placement = { center = vector.pack(0, math.huge, -2) } } },
      message = 'plugin desktop/monitors: option placement.center.y is not a finite number',
    },
    {
      patch = { id = 'desktop/errors', config = { background = { 1, 0, 0, 1, extra = true } } },
      message = 'plugin desktop/errors: option background.extra is not a positive integer array index',
    },
  } do
    local diagnostic = rejection(case.patch)
    expect.truthy(diagnostic:find(case.message, 1, true), diagnostic)
  end
end)

test('geometric desktop options reject lists and non-finite vector components', function()
  for _, case in ipairs {
    { id = 'desktop/hint', config = { position = { 0, 1.5, -1.5 } }, option = 'position' },
    { id = 'desktop/errors', config = { position = { 0, 1.4, -1.1 } }, option = 'position' },
    { id = 'desktop/menu', config = { offset = { 0, 0, 0 } }, option = 'offset' },
    { id = 'desktop/monitors', config = { placement = { center = { 0, 1.5, -2 } } }, option = 'placement.center' },
  } do
    local diagnostic = rejection { id = case.id, config = case.config }
    local message = 'plugin ' .. case.id .. ': option ' .. case.option .. ' is a vector, not a table'
    expect.truthy(diagnostic:find(message, 1, true), diagnostic)
  end
  for _, case in ipairs {
    { id = 'desktop/hint', config = { position = vector.pack(math.huge, 0, 0) }, option = 'position.x' },
    { id = 'desktop/errors', config = { position = vector.pack(0, 0, -math.huge) }, option = 'position.z' },
    { id = 'desktop/menu', config = { offset = vector.pack(0, math.huge, 0) }, option = 'offset.y' },
  } do
    local diagnostic = rejection { id = case.id, config = case.config }
    local message = 'plugin ' .. case.id .. ': option ' .. case.option .. ' is not a finite number'
    expect.truthy(diagnostic:find(message, 1, true), diagnostic)
  end
end)

test('a configured desktop serves what its patches configured, over the defaults', function()
  local services, owner = {}, nil
  local probe = plugin.define {
    name = 'probe',
    requires = {
      panels = panels.capability,
      interaction = interaction.capability,
      laser = laser.capability,
      rules = rules.capability,
      adoption = adoption.capability,
    },
    init = function(context)
      owner = context
      services.panels = context:require(panels.capability)
      services.interaction = context:require(interaction.capability)
      services.laser = context:require(laser.capability)
      services.rules = context:require(rules.capability)
      services.adoption = context:require(adoption.capability)
    end,
  }
  local session = testing.boot(desktop.compose {
    patches = {
      { id = 'panels', config = { height = 1.2, style = { borderThickness = 0.02 } } },
      { id = 'interaction', config = { tuning = { reach = 0.5, scrollScale = 7 } } },
      { id = 'laser', config = { style = { length = 2.5 } } },
      {
        id = 'desktop/pointing',
        config = { laser = { style = { color = { 0.9, 0.9, 0.9, 1 } }, tuning = { reach = 0.75 } } },
      },
      { id = 'rules', config = { precedence = 150 } },
      { id = 'adoption', config = { precedence = 350 } },
      { id = 'desktop/errors', config = { columns = 10 } },
      { insert = { id = 'probe', definition = probe } },
    },
  })
  local native = session.native
  for id, instance in pairs(session.instances) do
    if id == 'desktop/manager' then
      expect.equal(instance:state(), 'inactive', id)
      local diagnostic = tostring(instance:diagnostic())
      expect.truthy(diagnostic:find('waiting for a provider of lunette/composition@1', 1, true), diagnostic)
    else
      expect.equal(instance:state(), 'active', id)
    end
  end

  expect.equal(services.panels.STYLE.borderThickness, 0.02, 'the configured border')
  expect.equal(services.panels.STYLE.borderDepth, 0.001, 'a style key left out keeps its default')
  local panel = services.panels:fromWindow(owner, native.newWindow(90), {})
  expect.equal(panel.height, 1.2, 'a panel given no size takes the configured height')

  expect.equal(services.interaction.TUNING.reach, 0.5, 'the configured reach')
  local pointer = services.interaction:newPointer(owner)
  local near = {
    dead = false,
    raycast = function()
      return 0.5, 0.5, 1
    end,
  }
  pointer:update({ origin = vector.pack(0, 0, 0), direction = vector.pack(0, 0, -1), buttons = {}, grip = false }, {
    near,
  })
  expect.equal(pointer.hovered, nil, 'the reach limits picking')
  pointer:destroy()

  for _, hand in ipairs { 'left', 'right' } do
    local beam = assert(services.laser:forHand(hand))
    expect.equal(beam.style.length, 2.5, hand .. ' keeps the configured provider laser length')
    expect.equal(beam.style.color[1], 0.9, hand .. ' takes the pointing colour override')
    expect.equal(beam.pointer.tuning.reach, 0.75, hand .. ' takes the pointing reach override')
    expect.equal(beam.pointer.tuning.scrollScale, 7, hand .. ' keeps the configured provider scroll scale')
  end

  services.rules:setRules(owner, { name = 'probe', rules = {} })
  local precedences = {}
  for _, source in ipairs(services.rules:sources()) do
    precedences[source.name] = source.precedence
  end
  expect.equal(precedences.probe, 150, 'a rule set without a precedence takes the configured one')
  expect.equal(precedences['lunette.adoption'], 350, 'adoption installs its source at the configured precedence')

  local report = 'a report longer than ten columns'
  native.emit('onError', { message = report, traceback = '' })
  session:draw()
  local wrapped = {}
  for _, call in ipairs(native.events.draw) do
    local text = tostring(call[2])
    if call[1] == 'text' and text ~= '' and report:find(text, 1, true) then
      wrapped[#wrapped + 1] = text
    end
  end
  expect.equal(table.concat(wrapped, ' '), report, 'the error panel draws the whole report')
  for _, line in ipairs(wrapped) do
    expect.truthy(#line <= 10, 'the report wraps at the configured columns: ' .. line)
  end

  panel:destroy(owner)
  session:close()
end)

return test

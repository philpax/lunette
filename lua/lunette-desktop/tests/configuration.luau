-- Desktop entries reject unknown options, and a configured desktop serves its patches.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local desktop = require '@lunette-desktop'
local laser = require '@lunette-contracts/laser'

local test = testing.suite()

local function rejection(patch)
  testing.native()
  local running = testing.start(desktop.compose { patches = { patch } })
  local instance = running.instances[patch.id]
  expect.equal(instance:state(), 'failed', patch.id)
  local diagnostic = tostring(instance:diagnostic())
  running:close()
  expect.equal(#testing.takeReports(), 1, 'the failure of ' .. patch.id .. ' is reported')
  return diagnostic
end

test('a configured desktop serves its patches with pointing over the laser, and the error panel wraps', function()
  local rejected = rejection { id = 'desktop/hint', config = { bogus = 1 } }
  expect.truthy(rejected:find('plugin desktop/hint: option bogus is not a declared field', 1, true), rejected)

  local services = {}
  local probe = plugin.define {
    name = 'probe',
    requires = { laser = laser.capability },
    init = function(context)
      services.laser = context:require(laser.capability)
    end,
  }
  local session = testing.boot(desktop.compose {
    patches = {
      { id = 'laser', config = { style = { length = 2.5 } } },
      {
        id = 'desktop/pointing',
        config = { laser = { style = { color = { 0.9, 0.9, 0.9, 1 } }, tuning = { reach = 0.75 } } },
      },
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

  for _, hand in ipairs { 'left', 'right' } do
    local beam = assert(services.laser:forHand(hand))
    expect.equal(beam.style.length, 2.5, hand .. ' keeps the configured provider laser length')
    expect.equal(beam.style.color[1], 0.9, hand .. ' takes the pointing colour override')
    expect.equal(beam.pointer.tuning.reach, 0.75, hand .. ' takes the pointing reach override')
  end

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
  session:close()
end)

return test

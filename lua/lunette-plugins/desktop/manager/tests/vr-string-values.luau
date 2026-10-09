local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local schema = require '@lunette-plugin/schema'
local fixture = require './support/vr-manager'
local lunette = require '@lunette'
local suite = testing.suite()

local test = fixture.testCases(suite)

local function field(env, stage)
  local ok, description, control =
    pcall(env.controls.discover, env.controls, env.services.ui, 'desktop/manager', 'edit-field')
  assert(ok, (stage or 'field inspection') .. ': ' .. tostring(description))
  return control
end

test('manager edits escaped strings through VR without reports or inaccessible controls', function()
  local current
  local callback = function() end
  local values = {
    'first\nsecond',
    '\t',
    string.char(0, 1, 31, 127),
    utf8.char(0x80, 0x85, 0x9f),
    utf8.char(0x2028, 0x2029),
    string.char(255, 0xc0, 0xaf, 0xed, 0xa0, 0x80),
  }
  local descriptor = schema.object {
    values = schema.default(schema.array(schema.string()))(values),
    title = schema.default(schema.string()) '\\n literal',
    callback = schema.default(schema.callback(callback))(callback),
  }
  local definition = plugin.consumer({
    name = 'vr-string-consumer',
    schema = descriptor,
    init = function(_context, settings)
      current = settings
    end,
  }).definition
  local env = fixture.boot {
    { id = 'vr-string-consumer', definition = definition, config = { values = values } },
  }
  env:open()
  env:click('graph', 'node/' .. assert(env:entry 'vr-string-consumer').instanceId)
  env:click 'configure'
  for index, original in values do
    env:row('row/s:values/n:' .. tostring(index))
    expect.equal(field(env).kind, 'text-field', 'unsupported strings retain a real editable field')
    expect.equal(current.values[index], original, 'selecting does not replace the activation')
    env.controls:step()
    env.controls:step()
    expect.equal(#testing.takeReports(), 0, 'repeated frames do not report field creation failures')
    env:click 'confirm'
    env:click 'apply'
    expect.equal(current.values[index], original, 'unchanged confirmation preserves every byte')
    expect.equal(current.callback, callback, 'opaque callback identity survives Apply')
  end
  local codes = lunette.keyCodes()
  local board = env.services.keyboard:new(env.owner, {
    rows = {
      {
        { label = 'Slash', action = { kind = 'text', text = '\\' } },
        { label = 'Escape', action = { kind = 'text', text = '\\n\\x00\\xFF' } },
        { label = 'Text', action = { kind = 'text', text = 'next' } },
        { label = 'All', action = { kind = 'chord', code = codes.a, modifiers = { 'control' } } },
        { label = 'Enter', code = codes.enter },
      },
    },
    layers = {},
  })
  local offer = env.services.surfaces:offer(env.owner, {
    name = 'string-entry-keyboard',
    list = function()
      return if board.visible then { board } else {}
    end,
  })
  local function key(label)
    board:setPose(lovr.math.newMat4():translate(0, 0.8, -0.8))
    board:setVisible(true)
    for _, item in board:keys() do
      if item.legend == label then
        env.controls:click({
          pose = board.pose,
          width = board.width,
          height = board.height,
          logicalWidth = board.width,
          logicalHeight = board.height,
          visible = board.visible,
        }, item.x + item.width / 2, item.y + item.height / 2, 'left')
        board:setVisible(false)
        return
      end
    end
    error('escape-entry keyboard has no key ' .. label)
  end
  env:row 'row/s:values/n:1'
  env:click 'edit-field'
  key 'All'
  key 'Slash'
  env:click 'confirm'
  field(env, 'after rejected escape')
  expect.equal(current.values[1], values[1], 'rejection does not replace the activation')
  env.controls:step()
  env.controls:step()
  field(env, 'after rejection updates')
  expect.equal(#testing.takeReports(), 0, 'rejected escapes do not enter a report loop')
  env:click 'edit-field'
  key 'All'
  key 'Escape'
  env:click 'confirm'
  env:click 'apply'
  expect.equal(current.values[1], '\n\0' .. string.char(255), 'VR confirmation decodes every escaped byte')
  board:setVisible(false)
  env:row 'row/s:title'
  field(env, 'after selecting supported sibling')
  env:click 'confirm'
  env:click 'apply'
  expect.equal(current.title, '\\n literal', 'supported strings remain literal')
  env:row 'row/s:title'
  env:click 'edit-field'
  env:key 'All'
  env:key 'Text'
  env:click 'confirm'
  env:click 'apply'
  expect.equal(current.title, 'next', 'other rows remain reachable and editable')
  expect.equal(current.callback, callback, 'opaque siblings remain unchanged')
  env:row 'row/s:values/n:1'
  env:click 'edit-field'
  key 'All'
  key 'Slash'
  env:click 'confirm'
  field(env, 'before Close after rejection')
  env:click 'close'
  expect.equal(env:description().visible, false, 'Close remains reachable after a malformed escape rejection')
  offer:dispose()
  board:destroy()
  expect.equal(#testing.takeReports(), 0, 'the complete VR workflow produces no reports')
  env:close()
end)

return suite

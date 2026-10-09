local testing = require '@testing'
local expect = testing.expect
local contract = require '@lunette-contracts/focus'
local test = testing.suite()

local function scenario(run)
  testing.native()
  local session = testing.start { 'focus' }
  local observed = session:observe(contract.capability)
  run(observed.service, observed.context)
  session:close()
end

local function receiver()
  return {
    key = function()
      return false
    end,
    text = function()
      return true
    end,
  }
end

test('local registration validates closed plain metadata before acquiring effects', function()
  scenario(function(service, owner)
    local cases = {
      { { kind = 'other' }, 'kind is native or local' },
      { { kind = 'local', receiver = receiver(), wantsKeyboard = true, typo = true }, 'typo' },
      { { kind = 'local', receiver = receiver(), wantsKeyboard = 1 }, 'wantsKeyboard' },
      { { kind = 'local', receiver = {}, wantsKeyboard = true }, 'key and text' },
      {
        {
          kind = 'local',
          receiver = {
            key = function()
              return false
            end,
            text = 'wrong',
          },
          wantsKeyboard = true,
        },
        'key and text',
      },
      {
        {
          kind = 'local',
          receiver = {
            key = function()
              return false
            end,
            text = function()
              return false
            end,
            onBlur = 1,
          },
          wantsKeyboard = true,
        },
        'onBlur',
      },
      {
        {
          kind = 'local',
          receiver = {
            key = function()
              return false
            end,
            text = function()
              return false
            end,
            onFocus = 1,
          },
          wantsKeyboard = true,
        },
        'onFocus',
      },
      { { kind = 'local', receiver = setmetatable(receiver(), {}), wantsKeyboard = true }, 'plain table' },
      { setmetatable({ kind = 'local', receiver = receiver(), wantsKeyboard = true }, {}), 'plain table' },
      { { kind = 'native' }, 'sink is required' },
      { { kind = 'native', sink = { domain = 'other', dead = false } }, 'sink domain' },
    }
    for _, case in ipairs(cases) do
      expect.raises(function()
        service:register(owner, case[1])
      end, case[2], 'named invalid target')
      expect.equal(#service:inspect().registrations, 0, 'invalid data acquires no registration')
    end
  end)
end)

test('registration copies receiver and target data without exposing mutable implementation state', function()
  scenario(function(service, owner)
    local text = ''
    local callbacks = receiver()
    callbacks.text = function(value)
      text ..= value
      return true
    end
    local options = { kind = 'local', receiver = callbacks, wantsKeyboard = true }
    local target = service:register(owner, options)
    options.wantsKeyboard = false
    callbacks.text = function()
      error 'mutated caller callback cannot replace a registered receiver'
    end
    target:focus()
    local input = service:newSource(owner)
    expect.equal(input:text('draft').kind, 'consumed', 'the registered callback is retained')
    expect.equal(text, 'draft', 'caller changes do not mutate registered delivery')
    expect.raises(function()
      target.dead = false
    end, 'readonly', 'handles are readonly')
    expect.raises(function()
      target.extra = true
    end, 'readonly', 'handles reject new properties')
    target:destroy()
    expect.equal(input:text('ignored').kind, 'unhandled', 'destroyed target delivery is inert')
  end)
end)

test('source options reject metatables and activation metadata rejects malformed containers', function()
  scenario(function(service, owner)
    expect.raises(function()
      service:newSource(owner, setmetatable({ mode = 'virtual' }, {}))
    end, 'plain table', 'source options are plain data')
    local input = service:newSource(owner)
    for _, activation in
      {
        { code = 30, typo = true },
        { code = 30, modifiers = setmetatable({}, {}) },
        { code = 30, modifiers = { [2] = 'shift' } },
        { code = 30, modifiers = { 'shift', 1 } },
        { code = 30, isRepeat = 1 },
        { code = 30, batch = 0 / 0 },
        { code = 79, physicalModifiers = false },
        { code = 79, physicalModifiers = {} },
        { code = 79, physicalModifiers = setmetatable({}, {}) },
        {
          code = 79,
          physicalModifiers = {
            shift = false,
            control = false,
            alt = false,
            super = false,
            capsLock = false,
            numLock = 1,
          },
        },
        {
          code = 79,
          physicalModifiers = {
            shift = false,
            control = false,
            alt = false,
            super = false,
            capsLock = false,
            numLock = true,
            typo = false,
          },
        },
        setmetatable({ code = 30 }, {}),
      }
    do
      expect.equal(input:key(activation).kind, 'refused', 'invalid activation is refused before delivery')
    end
    expect.raises(function()
      input:beginBatch(math.huge)
    end, 'batch', 'batch ids must be finite')
  end)
end)

return test

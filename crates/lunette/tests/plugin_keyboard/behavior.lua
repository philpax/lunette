return function()
  local plugin = require '@lunette-plugin'
  local contract = require '@lunette-contracts/keyboard'
  local interaction = require '@lunette-contracts/interaction'
  local definition = require('@lunette-plugins/keyboard').definition
  assert(allocations == 0)
  assert(require('@lunette-plugins/keyboard').definition == definition)
  local panelsDefinition = require('@lunette-plugins/panels').definition
  local interactionDefinition = require('@lunette-plugins/interaction').definition
  local function setup()
    local runtime = plugin.runtime()
    runtime:use(panelsDefinition, {}):enable()
    runtime:use(interactionDefinition, {}):enable()
    local provider = runtime:use(definition, {})
    provider:enable()
    local service, owner, focus
    local consumer = runtime:use(
      plugin.define {
        name = 'behavior-1',
        requires = { keyboard = contract.capability, interaction = interaction.capability },
        init = function(ctx)
          service, owner, focus = ctx:require(contract.capability), ctx, ctx:require(interaction.capability)
        end,
      },
      {}
    )
    consumer:enable()
    assert(service, 'consumer activated')
    return runtime, provider, consumer, service, owner, focus
  end
  local runtime, provider, consumer, service, owner, focus = setup()
  local weakResources = setmetatable({}, { __mode = 'v' })
  for cycle = 1, 12 do
    do
      local board = service:new(owner)
      weakResources[1] = board
      assert(board:destroy())
      assert(not board:destroy())
    end
    collectResources()
    collectResources()
    assert(weakResources[1] == nil, 'destroyed keyboard retained by active owner')
  end
  local otherRuntime, _, _, otherService, otherOwner = setup()
  local before = allocations
  assert(not pcall(function()
    service:new(otherOwner)
  end))
  assert(allocations == before, 'foreign owner rejected before allocation')
  local events = {}
  local seat = { dead = false }
  function seat:characterFor(code, held)
    if code == 30 then
      return table.find(held, 'shift') and 'Q' or 'q'
    end
  end
  function seat:symbolFor()
    return 123
  end
  function seat:strokeFor(text)
    if text == 'q' then
      return { keycode = 30, modifiers = {} }
    end
    if text == 'Q' then
      return { keycode = 30, modifiers = { 'shift' } }
    end
  end
  local sink = { dead = false }
  function sink:modifiers(held, actual)
    assert(actual == seat)
    events[#events + 1] = { 'modifiers', table.clone(held) }
    return true
  end
  function sink:key(code, pressed, actual)
    assert(actual == seat)
    events[#events + 1] = { 'key', code, pressed }
    return true
  end
  function sink:typeText(text, actual)
    assert(actual == seat)
    events[#events + 1] = { 'text', text }
    return true
  end
  function seat:setFocus(target)
    self.focus = target
    return true
  end
  focus:setFocus(owner, { seat = seat, sink = sink })
  assert(seat.focus == sink)
  local board = service:new(owner)
  local keys = board:keys()
  local wanted
  for _, key in ipairs(keys) do
    if key.code == 30 then
      wanted = key
    end
  end
  assert(wanted.legend == 'q')
  board:pressKey(42)
  board:pressKey(30)
  assert(events[1][2][1] == 'shift' and events[2][3] == true and events[3][3] == false)
  assert(#board:modifiers() == 0)
  board:pressKey(58)
  board:pressKey(30)
  assert(board:modifiers()[1] == 'capsLock')
  local width = board.width
  board:setSize(width * 2)
  assert(board.width == width * 2)
  board:setVisible(false)
  board:draw {}
  board:setVisible(true)
  table.clear(events)
  board:typeText 'qüßQ'
  assert(events[4][1] == 'text' and events[4][2] == 'üß')
  consumer:disable()
  assert(board.dead)
  assert(seat.focus == nil, 'the focus the consumer held ends with it')
  assert(events[#events][1] == 'modifiers' and #events[#events][2] == 0)
  local count = #events
  assert(not board:destroy())
  assert(#events == count)
  assert(not pcall(function()
    service:new(owner)
  end))
  provider:disable()
  provider:enable()
  assert(otherService:new(otherOwner), "another runtime's provider is unaffected")
  -- A keyboard release that fails while its owner unloads is that owner's
  -- failure: the owner is quarantined and the keyboard provider keeps serving.
  local failRuntime, failProvider, failConsumer, failService, failOwner, failFocus = setup()
  local failSeat = { dead = false }
  function failSeat:setFocus(target)
    self.focus = target
    return true
  end
  local failing = false
  local failedReleases = 0
  local failSink = { dead = false }
  function failSink:modifiers(_held, _seat)
    if failing then
      failedReleases += 1
      error 'native keyboard release failed'
    end
    return true
  end
  function failSink:key(_code, _pressed, _seat)
    return true
  end
  failFocus:setFocus(failOwner, { seat = failSeat, sink = failSink })
  local failBoard = failService:new(failOwner)
  failBoard:pressKey(30)
  failing = true
  failConsumer:disable()
  assert(failedReleases == 1 and failBoard.dead, 'the release ran once')
  assert(failConsumer:state() == 'quarantined', 'the failing owner is quarantined: ' .. failConsumer:state())
  assert(failProvider:state() == 'active', 'the keyboard provider is not quarantined: ' .. failProvider:state())
  local survivorService, survivorOwner
  local survivor = failRuntime:use(
    plugin.define {
      name = 'behavior-2',
      requires = { keyboard = contract.capability },
      init = function(ctx)
        survivorService, survivorOwner = ctx:require(contract.capability), ctx
      end,
    },
    {}
  )
  survivor:enable()
  assert(survivorService:new(survivorOwner), 'the keyboard provider serves another owner')
  failRuntime:close()
  otherRuntime:close()
  runtime:close()
end

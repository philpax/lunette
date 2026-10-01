return function()
  local plugin = require '@lunette-plugin'
  local contract = require '@lunette-contracts/keyboard'
  local interaction = require '@lunette-contracts/interaction'
  local definition = require '@lunette-plugins/keyboard'
  assert(allocations == 0)
  assert(require '@lunette-plugins/keyboard' == definition)
  local panelsDefinition = require '@lunette-plugins/panels'
  local interactionDefinition = require '@lunette-plugins/interaction'
  local function identity(value)
    return value
  end
  local function setup()
    local runtime = plugin.runtime()
    runtime:use(panelsDefinition, {}):enable()
    runtime:use(interactionDefinition, {}):enable()
    local provider = runtime:use(definition, {})
    provider:enable()
    local service, owner, focus
    local consumer = runtime:use(
      plugin.define(
        identity,
        { keyboard = contract.capability, interaction = interaction.capability },
        {},
        function(ctx)
          service, owner, focus = ctx:require(contract.capability), ctx, ctx:require(interaction.capability)
        end
      ),
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
  focus:setFocus(owner, seat, sink)
  assert(seat.focus == sink)
  local board = service:new(owner)
  assert(#service:all() == 1 and #otherService:all() == 0)
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
  board:setHovered(keys[1], 'left')
  board:setHovered(keys[2], 'right')
  board:onLeave 'left'
  assert(not board:isHovered(keys[1].code) and board:isHovered(keys[2].code))
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
  assert(board.dead and #service:all() == 0)
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
  assert(#otherService:all() == 0)
  otherRuntime:close()
  runtime:close()
end

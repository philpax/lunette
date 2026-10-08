local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local surfaces = require '@lunette-contracts/surfaces'
local vrUi = require '@testing/vr-ui'
local test = testing.suite()

local function boot()
  local running = vrUi.boot {
    'theme',
    'frame',
    'surfaces',
    'drops',
    'focus',
    'interaction',
    'laser',
    'keyboard',
    'desktop/pointing',
    'ui',
  }
  local state = { fixture = running, events = {} }
  state.instance = running.session:use(plugin.define {
    name = 'testing/input-panel',
    requires = { ui = ui.capability },
    init = function(context)
      state.owner = context
      state.service = context:require(ui.capability)
      state.panel = state.service:newPanel(context, {
        name = 'input-lifecycle',
        pose = lovr.math.newMat4():translate(0, 1.5, -2),
        width = 2,
        height = 1,
        logicalWidth = 400,
        logicalHeight = 200,
      })
    end,
  })
  return state
end

local function withPanel(run)
  local state = boot()
  local ok, failure = pcall(run, state)
  state.fixture:close()
  if not ok then
    error(failure, 0)
  end
end

local function region(state, id, x, options)
  options = options or {}
  options.id = id
  options.bounds = { x = x, y = 20, width = 120, height = 100 }
  local callback = options.onPointer
  options.onPointer = function(event)
    state.events[#state.events + 1] = { id = id, event = event }
    if callback then
      callback(event)
    end
  end
  return state.panel:region(state.owner, options)
end

local function press(state, id, hand)
  local description, control = state.fixture:discover(state.service, 'input-lifecycle', id)
  local bounds = control.bounds
  state.fixture:button(hand, 'trigger', false)
  state.fixture:aim(description, bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, hand)
  state.fixture:step()
  state.beforePressHaptics = state.fixture.native.events.haptics or 0
  state.fixture:button(hand, 'trigger', true)
  state.fixture:step()
end

local function matching(state, id, kind)
  local result = {}
  for _, recorded in ipairs(state.events) do
    if recorded.id == id and recorded.event.kind == kind then
      result[#result + 1] = recorded.event
    end
  end
  return result
end

local function receiver(onFocus)
  return {
    key = function()
      return false
    end,
    text = function()
      return false
    end,
    onFocus = onFocus,
  }
end

test('a press callback that cancels its capture cannot continue to haptics', function()
  for _, change in ipairs { 'bounds', 'disable', 'destroy', 'hide' } do
    withPanel(function(state)
      local control
      control = region(state, 'first', 20, {
        onPointer = function(event)
          if event.kind ~= 'press' then
            return
          end
          if change == 'bounds' then
            control:setBounds { x = 30, y = 20, width = 120, height = 100 }
          elseif change == 'disable' then
            control:setEnabled(false)
          elseif change == 'destroy' then
            control:destroy()
          else
            state.panel:setVisible(false)
          end
        end,
      })
      press(state, 'first', 'right')
      expect.equal(#matching(state, 'first', 'press'), 1, change .. ' begins the press')
      expect.equal(#matching(state, 'first', 'cancel'), 1, change .. ' cancels the original capture')
      expect.equal(
        state.fixture.native.events.haptics or 0,
        state.beforePressHaptics,
        change .. ' cannot pulse after cancellation'
      )
      state.fixture:step()
      state.fixture:button('right', 'trigger', false)
      state.fixture:step()
      expect.equal(#matching(state, 'first', 'release'), 0, change .. ' suppresses the stale release')
    end)
  end
end)

test('focus observers cannot deliver a press after cancelling its original control', function()
  for _, change in ipairs { 'bounds', 'disable', 'destroy', 'hide', 'panel' } do
    withPanel(function(state)
      local control
      control = region(state, 'first', 20, {
        receiver = receiver(function()
          if change == 'bounds' then
            control:setBounds { x = 30, y = 20, width = 120, height = 100 }
          elseif change == 'disable' then
            control:setEnabled(false)
          elseif change == 'destroy' then
            control:destroy()
          elseif change == 'hide' then
            state.panel:setVisible(false)
          else
            state.panel:destroy()
          end
        end),
      })
      press(state, 'first', 'right')
      expect.equal(#matching(state, 'first', 'press'), 0, change .. ' prevents post-focus press delivery')
      expect.equal(#matching(state, 'first', 'cancel'), 1, change .. ' delivers one deliberate terminal cancel')
      expect.equal(
        state.fixture.native.events.haptics or 0,
        state.beforePressHaptics,
        change .. ' prevents a stale pulse'
      )
    end)
  end
end)

test('nested destruction consumes each queued cancel and leave before the other target ends', function()
  withPanel(function(state)
    local controls, ended, stale = {}, {}, 0
    for index, id in ipairs { 'first', 'second' } do
      local other = if id == 'first' then 'second' else 'first'
      controls[id] = region(state, id, 20 + (index - 1) * 180, {
        onPointer = function(event)
          if ended[id] then
            stale += 1
          end
          if event.kind == 'cancel' and not controls[other].dead then
            controls[other]:destroy()
            ended[other] = true
          end
        end,
      })
    end
    press(state, 'first', 'left')
    press(state, 'second', 'right')
    state.panel:setVisible(false)
    for _, id in ipairs { 'first', 'second' } do
      expect.equal(#matching(state, id, 'cancel'), 1, id .. ' has one terminal cancel')
      expect.equal(#matching(state, id, 'leave'), 1, id .. ' has one terminal leave')
    end
    expect.equal(stale, 0, 'pending terminal events run before nested target destruction returns')
    state.fixture:step()
    state.fixture:button('left', 'trigger', false)
    state.fixture:button('right', 'trigger', false)
    state.fixture:step()
    expect.equal(
      #matching(state, 'first', 'release') + #matching(state, 'second', 'release'),
      0,
      'neither held capture releases'
    )
  end)
end)

test('queued terminal callbacks stop when an earlier callback ends their owner', function()
  withPanel(function(state)
    local instances, ended, stale = {}, {}, 0
    for index, id in ipairs { 'first', 'second' } do
      local other = if id == 'first' then 'second' else 'first'
      instances[id] = state.fixture.session:use(plugin.define {
        name = 'testing/input-' .. id,
        requires = { ui = ui.capability },
        init = function(context)
          state.panel:region(context, {
            id = id,
            bounds = { x = 20 + (index - 1) * 180, y = 20, width = 120, height = 100 },
            onPointer = function(event)
              state.events[#state.events + 1] = { id = id, event = event }
              if ended[id] then
                stale += 1
              end
              if event.kind == 'cancel' and not ended[other] then
                ended[other] = true
                instances[other]:disable()
              end
            end,
          })
        end,
      })
    end
    press(state, 'first', 'left')
    press(state, 'second', 'right')
    state.panel:setVisible(false)
    expect.equal(stale, 0, 'no pointer callback runs after its owner ends')
    expect.equal(
      #matching(state, 'first', 'cancel') + #matching(state, 'second', 'cancel'),
      1,
      'only the still-live owner receives cancellation'
    )
  end)
end)

test('a leave observer cannot continue into a stale hover selection', function()
  for _, change in ipairs { 'bounds', 'disable', 'destroy', 'hide' } do
    withPanel(function(state)
      local second
      region(state, 'first', 20, {
        onPointer = function(event)
          if event.kind ~= 'leave' then
            return
          end
          if change == 'bounds' then
            second:setBounds { x = 200, y = 140, width = 120, height = 50 }
          elseif change == 'disable' then
            second:setEnabled(false)
          elseif change == 'destroy' then
            second:destroy()
          else
            state.panel:setVisible(false)
          end
        end,
      })
      second = region(state, 'second', 200)
      local description = state.panel:describe()
      state.fixture:aim(description, 60, 60, 'right')
      state.fixture:step()
      state.fixture:aim(description, 240, 60, 'right')
      state.fixture:step()
      expect.equal(#matching(state, 'second', 'enter'), 0, change .. ' prevents the stale enter')
    end)
  end
end)

test('control-local cancellation preserves another pointer capture and suppresses a held trigger', function()
  withPanel(function(state)
    local first = region(state, 'first', 20)
    region(state, 'second', 200)
    press(state, 'first', 'left')
    press(state, 'second', 'right')
    first:setEnabled(false)
    first:setEnabled(true)
    state.fixture:step()
    expect.equal(#matching(state, 'first', 'press'), 1, 'a held trigger cannot reactivate after local cancellation')
    expect.equal(#matching(state, 'first', 'cancel'), 1, 'only the selected control cancels')
    expect.equal(#matching(state, 'second', 'cancel'), 0, 'the other control stays captured')
    state.fixture:button('left', 'trigger', false)
    state.fixture:button('right', 'trigger', false)
    state.fixture:step()
    expect.equal(#matching(state, 'first', 'release'), 0, 'the cancelled control cannot release')
    expect.equal(#matching(state, 'second', 'release'), 1, 'the other capture releases normally')
    press(state, 'first', 'left')
    expect.equal(#matching(state, 'first', 'press'), 2, 'a new trigger edge can activate again')
  end)
end)

test('synthetic enter leave and cancellation events are immutable', function()
  withPanel(function(state)
    region(state, 'first', 20)
    press(state, 'first', 'right')
    state.panel:setVisible(false)
    for _, kind in ipairs { 'enter', 'cancel', 'leave' } do
      local event = matching(state, 'first', kind)[1]
      expect.truthy(event, kind .. ' is delivered')
      expect.truthy(table.isfrozen(event), kind .. ' is frozen')
      expect.falsy(
        pcall(function()
          event.inside = true
        end),
        kind .. ' cannot be changed by an observer'
      )
    end
  end)
end)

test('pointer cancellation failures cannot skip another pointer or target inverse', function()
  withPanel(function(state)
    region(state, 'first', 20)
    region(state, 'second', 200)
    local observed = state.fixture.session:observe(surfaces.capability)
    local offered = observed.service:all()[1]
    local attempts = 0
    for index, x in ipairs { 60, 240 } do
      local pointer = {
        cancel = function()
          attempts += 1
          error('cancel failure ' .. index)
        end,
        vibrate = function()
          return false
        end,
      }
      for _, kind in ipairs { 'enter', 'move', 'press' } do
        offered:onPointer(table.freeze {
          kind = kind,
          pointer = pointer,
          x = x,
          y = 60,
          button = if kind == 'press' then 'left' else nil,
          inside = true,
          captured = kind == 'press',
        })
      end
    end
    local ok, failure = pcall(function()
      state.panel:destroy()
    end)
    expect.falsy(ok, 'cleanup reports pointer cancellation failures')
    expect.truthy(string.find(tostring(failure), 'cancel failure', 1, true), 'cleanup retains the failure')
    expect.equal(attempts, 2, 'both pointer inverses run')
    for _, id in ipairs { 'first', 'second' } do
      expect.equal(#matching(state, id, 'cancel'), 1, id .. ' cancellation is attempted')
      expect.equal(#matching(state, id, 'leave'), 1, id .. ' leave is attempted')
    end
    expect.equal(#observed.service:all(), 0, 'the surface inverse still removes the offer')
    expect.falsy(state.panel:destroy(), 'a second destruction is inert')
  end)
end)

return test

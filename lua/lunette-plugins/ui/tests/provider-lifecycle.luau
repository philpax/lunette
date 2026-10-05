local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local vrUi = require '@testing/vr-ui'
local substitute = require '@testing/ui-substitute'
local test = testing.suite()

local function withPanel(provider, run)
  local running = vrUi.boot {
    'frame',
    'surfaces',
    'drops',
    'focus',
    'interaction',
    'laser',
    'keyboard',
    'desktop/pointing',
    provider,
  }
  local state = { fixture = running, events = {} }
  local ok, failure = pcall(function()
    state.instance = running.session:use(plugin.define {
      name = 'testing/provider-lifecycle',
      requires = { ui = ui.capability },
      init = function(context)
        state.owner = context
        state.service = context:require(ui.capability)
        state.panel = state.service:newPanel(context, {
          name = 'provider-lifecycle',
          pose = lovr.math.newMat4():translate(0, 1.5, -2),
          width = 2,
          height = 1,
          logicalWidth = 400,
          logicalHeight = 200,
        })
      end,
    })
    run(state)
  end)
  local closed, cleanup = pcall(function()
    running:close()
  end)
  if not ok then
    error(tostring(failure) .. (if closed then '' else '\ncleanup: ' .. tostring(cleanup)), 0)
  end
  if not closed then
    error(cleanup, 0)
  end
end

local function region(state, owner, id, x, options)
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
  return state.panel:region(owner, options)
end

local function press(state, id, hand)
  local description, control = state.fixture:discover(state.service, 'provider-lifecycle', id)
  local bounds = assert(control.bounds)
  state.fixture:button(hand, 'trigger', false)
  state.fixture:aim(description, bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, hand)
  state.fixture:step()
  state.beforePressHaptics = state.fixture.native.events.haptics or 0
  state.fixture:button(hand, 'trigger', true)
  state.fixture:step()
end

local function count(state, id, kind)
  local result = 0
  for _, recorded in ipairs(state.events) do
    if recorded.id == id and recorded.event.kind == kind then
      result += 1
    end
  end
  return result
end

local function release(state)
  state.fixture:step()
  state.fixture:button('left', 'trigger', false)
  state.fixture:button('right', 'trigger', false)
  state.fixture:step()
end

local function changeControl(state, control, change)
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
end

for _, provider in ipairs {
  { name = 'built-in', entry = 'ui' },
  { name = 'substitute', entry = { id = 'ui', definition = substitute.definition } },
} do
  for _, change in ipairs { 'bounds', 'disable', 'destroy', 'hide', 'panel' } do
    test(provider.name .. ' focus ' .. change .. ' suppresses the original press and haptic', function()
      withPanel(provider.entry, function(state)
        local control
        control = region(state, state.owner, 'first', 20, {
          receiver = {
            key = function()
              return false
            end,
            text = function()
              return false
            end,
            onFocus = function()
              changeControl(state, control, change)
            end,
          },
        })
        press(state, 'first', 'right')
        expect.equal(count(state, 'first', 'press'), 0, 'focus invalidation prevents a stale press')
        expect.equal(count(state, 'first', 'cancel'), 1, 'the original capture receives one terminal cancel')
        expect.equal(
          state.fixture.native.events.haptics or 0,
          state.beforePressHaptics,
          'focus invalidation prevents a stale haptic'
        )
        release(state)
        expect.equal(count(state, 'first', 'release'), 0, 'the cancelled trigger cannot release')
      end)
    end)
  end

  for _, change in ipairs { 'bounds', 'disable', 'destroy', 'hide' } do
    test(provider.name .. ' press ' .. change .. ' cannot continue to a haptic or release', function()
      withPanel(provider.entry, function(state)
        local control
        control = region(state, state.owner, 'first', 20, {
          onPointer = function(event)
            if event.kind == 'press' then
              changeControl(state, control, change)
            end
          end,
        })
        press(state, 'first', 'right')
        expect.equal(count(state, 'first', 'press'), 1, 'the press begins once')
        expect.equal(count(state, 'first', 'cancel'), 1, 'the press callback cancels its original capture once')
        expect.equal(
          state.fixture.native.events.haptics or 0,
          state.beforePressHaptics,
          'a cancelled press cannot pulse'
        )
        release(state)
        expect.equal(count(state, 'first', 'release'), 0, 'a cancelled press cannot release')
      end)
    end)
  end

  test(provider.name .. ' captured region owner teardown never invokes its ended owner', function()
    withPanel(provider.entry, function(state)
      local owner, control
      local instance = state.fixture.session:use(plugin.define {
        name = 'testing/provider-region-owner',
        requires = { ui = ui.capability },
        init = function(context)
          owner = context
          control = region(state, context, 'first', 20)
        end,
      })
      press(state, 'first', 'right')
      local before = #state.events
      instance:disable()
      expect.falsy(owner:active(), 'the region owner ended')
      expect.truthy(control.dead, 'owner teardown invalidates its region')
      expect.falsy(state.panel.dead, 'the other owner retains its panel')
      expect.equal(#state.events, before, 'an ended owner receives no terminal callback')
      release(state)
      expect.equal(count(state, 'first', 'release'), 0, 'the ended owner receives no stale release')
    end)
  end)

  test(provider.name .. ' nested destruction consumes queued terminal callbacks exactly once', function()
    withPanel(provider.entry, function(state)
      local controls, ended, stale = {}, {}, 0
      for index, id in ipairs { 'first', 'second' } do
        local other = if id == 'first' then 'second' else 'first'
        controls[id] = region(state, state.owner, id, 20 + (index - 1) * 180, {
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
        expect.equal(count(state, id, 'cancel'), 1, id .. ' receives exactly one terminal cancel')
      end
      for _, id in ipairs { 'first', 'second' } do
        expect.equal(count(state, id, 'leave'), 1, id .. ' receives exactly one terminal leave')
      end
      expect.equal(stale, 0, 'queued terminals run before nested target destruction returns')
      release(state)
      expect.equal(count(state, 'first', 'release') + count(state, 'second', 'release'), 0, 'no stale release')
    end)
  end)

  test(provider.name .. ' queued terminal callbacks recheck owners after every callback', function()
    withPanel(provider.entry, function(state)
      local instances, owners, stale = {}, {}, 0
      for index, id in ipairs { 'first', 'second' } do
        local other = if id == 'first' then 'second' else 'first'
        instances[id] = state.fixture.session:use(plugin.define {
          name = 'testing/provider-owner-' .. id,
          requires = { ui = ui.capability },
          init = function(context)
            owners[id] = context
            region(state, context, id, 20 + (index - 1) * 180, {
              onPointer = function(event)
                if not context:active() then
                  stale += 1
                end
                if event.kind == 'cancel' and owners[other]:active() then
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
      expect.equal(stale, 0, 'no callback enters an ended owner')
      expect.equal(
        count(state, 'first', 'cancel') + count(state, 'second', 'cancel'),
        1,
        'only the owner still live at delivery receives a cancel'
      )
    end)
  end)

  test(provider.name .. ' a terminal callback failure is labelled and cannot skip later cleanup', function()
    withPanel(provider.entry, function(state)
      for index, id in ipairs { 'first', 'second' } do
        region(state, state.owner, id, 20 + (index - 1) * 180, {
          onPointer = function(event)
            if event.kind == 'cancel' then
              error('terminal observer failure ' .. id)
            end
          end,
        })
      end
      press(state, 'first', 'left')
      press(state, 'second', 'right')
      state.panel:setVisible(false)
      local reports = state.fixture.native.events.reported
      expect.equal(#reports, 2, 'each failing terminal observer reports once')
      for _, report in ipairs(reports) do
        expect.truthy(string.find(report.message, 'provider-lifecycle', 1, true), 'the label names the owner')
        expect.truthy(
          string.find(report.message, 'first', 1, true) or string.find(report.message, 'second', 1, true),
          'the label names the region'
        )
        expect.truthy(string.find(report.message, 'terminal observer failure', 1, true), 'the failure is retained')
      end
      expect.equal(#testing.takeReports(), 0, 'protected observer errors are not plugin lifecycle failures')
      expect.equal(count(state, 'first', 'cancel'), 1, 'the first cancel runs once')
      expect.equal(count(state, 'second', 'cancel'), 1, 'the later cancel still runs once')
      release(state)
      expect.equal(count(state, 'first', 'release') + count(state, 'second', 'release'), 0, 'cleanup detached captures')
    end)
  end)
end

return test

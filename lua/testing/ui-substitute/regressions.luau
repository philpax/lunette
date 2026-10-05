-- Public-consumer regressions for owner identity, detached options, and focus failure boundaries.

local testing = require '@testing'
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local surfaces = require '@lunette-contracts/surfaces'
local expect = testing.expect
local regressions = {}

local function button(panel, owner, id)
  return panel:button(owner, {
    id = id,
    bounds = { x = 5, y = 5, width = 20, height = 20 },
    onActivate = function() end,
  })
end

function regressions.register(test)
  test('owner-local ids span panels and expose stable opaque owner identities', function(running, state)
    local second = state.service:newPanel(state.context, {
      name = 'Owner ids',
      width = 1,
      height = 1,
      logicalWidth = 100,
      logicalHeight = 100,
    })
    local first = button(state.panel, state.context, 'owner-id')
    expect.raises(function()
      button(second, state.context, 'owner-id')
    end, 'duplicate control id')
    expect.equal(first.owner, state.button.owner)
    expect.equal(first.owner.kind, 'ui-owner')
    expect.equal(first.owner.services, nil, 'identity exposes no owner context')
    expect.equal(first.owner.effect, nil)
    expect.raises(function()
      first.owner.kind = 'changed'
    end)
    local described
    for _, entry in state.panel:describe().controls do
      if entry.id == first.id and entry.owner == first.owner then
        described = entry
      end
    end
    expect.truthy(described, 'the public description carries the handle identity')
    local other = {}
    other.instance = running.session:use(plugin.define {
      name = 'testing/ui-other-owner',
      requires = { ui = ui.capability },
      init = function(context)
        other.context = context
        other.button = button(state.panel, context, 'owner-id')
      end,
    })
    expect.truthy(other.button.owner ~= first.owner, 'another live owner can reuse an id in the same panel')
    local token = first.owner
    first:destroy()
    local reused = button(second, state.context, 'owner-id')
    expect.equal(reused.owner, token, 'destroying a control releases its id, not its owner token')
    local otherToken = other.button.owner
    other.instance:disable()
    expect.truthy(other.button.dead)
    other.instance:enable()
    expect.truthy(other.button.owner ~= otherToken, 'the reactivated owner has a fresh identity')
    local previous = reused.owner
    state.consumer:reload {}
    expect.truthy(reused.dead)
    expect.truthy(state.button.owner ~= previous, 'a replacement owner activation gets a fresh token')
  end)

  test('themes and callback options are detached from caller tables and frozen in visuals', function(running, state)
    local color = { 0.12, 0.23, 0.34, 1 }
    local overrides = { background = color }
    local snapshots = {}
    local panelOptions = {
      name = 'Detached panel',
      width = 1,
      height = 1,
      logicalWidth = 100,
      logicalHeight = 100,
      theme = overrides,
      draw = function(_, visual)
        snapshots.panel = visual
      end,
    }
    local panel = state.service:newPanel(state.context, panelOptions)
    local count = 0
    local controlOptions = {
      id = 'detached',
      bounds = { x = 10, y = 10, width = 20, height = 20 },
      theme = { control = { 0.45, 0.56, 0.67, 1 } },
      onActivate = function()
        count += 1
      end,
      draw = function(_, visual)
        snapshots.control = visual
      end,
    }
    local control = panel:button(state.context, controlOptions)
    color[1] = 0.9
    overrides.padding = 99
    panelOptions.draw = function()
      error 'mutated panel hook'
    end
    controlOptions.theme.control[1] = 0.9
    controlOptions.bounds.x = 70
    controlOptions.onActivate = function()
      count += 100
    end
    controlOptions.draw = function()
      error 'mutated control hook'
    end
    panel:draw(running.native.events.pass)
    expect.equal(snapshots.panel.theme.background[1], 0.12)
    expect.equal(snapshots.control.theme.control[1], 0.45)
    expect.raises(function()
      snapshots.control.theme.foreground[1] = 0
    end)
    expect.raises(function()
      snapshots.panel.theme.background[1] = 0
    end)
    expect.equal(panel:describe().controls[1].bounds.x, 10)
    local replacement = { control = { 0.22, 0.33, 0.44, 1 } }
    control:setTheme(replacement)
    replacement.control[1] = 0.8
    panel:draw(running.native.events.pass)
    expect.equal(snapshots.control.theme.control[1], 0.22)
    local surface
    for _, candidate in running.session:observe(surfaces.capability).service:all() do
      if candidate.width == 1 then
        surface = candidate
      end
    end
    local pointer = { cancel = function() end }
    surface:onPointer {
      kind = 'press',
      pointer = pointer,
      button = 'left',
      x = 15,
      y = 15,
      inside = true,
      captured = true,
    }
    surface:onPointer {
      kind = 'release',
      pointer = pointer,
      button = 'left',
      x = 15,
      y = 15,
      inside = true,
      captured = true,
    }
    expect.equal(count, 1, 'the original callback is retained independently')
    expect.equal(#running.native.events.reported, 0)
  end)

  test('region key and text failures return failed with one owner-labelled focus report', function(running, state)
    local receiver = {
      key = function()
        error 'region key failure'
      end,
      text = function()
        error 'region text failure'
      end,
    }
    state.panel:region(state.context, {
      id = 'failing-region',
      bounds = { x = 10, y = 160, width = 80, height = 30 },
      receiver = receiver,
    })
    receiver.key = function()
      return true
    end
    receiver.text = function()
      return true
    end
    running:clickControl(state.service, 'Contract controls', 'failing-region')
    local first = #running.native.events.reported
    expect.equal(state.source:key({ code = lunette.keyCodes().a }).kind, 'failed')
    expect.equal(#running.native.events.reported - first, 1)
    expect.truthy(running.native.events.reported[first + 1].message:find 'testing/ui%-contract%-consumer')
    expect.truthy(running.native.events.reported[first + 1].message:find 'region key failure')
    first = #running.native.events.reported
    expect.equal(state.source:text('input').kind, 'failed')
    expect.equal(#running.native.events.reported - first, 1)
    expect.truthy(running.native.events.reported[first + 1].message:find 'region text failure')
    expect.equal(#testing.takeReports(), 0)
  end)

  test('text change and submit failures report once while deliveries stay consumed', function(running, state)
    local field = state.panel:textField(state.context, {
      id = 'failing-field',
      bounds = { x = 100, y = 160, width = 150, height = 30 },
      onChange = function()
        error 'field change failure'
      end,
      onSubmit = function()
        error 'field submit failure'
      end,
    })
    expect.truthy(field:focus())
    local first = #running.native.events.reported
    expect.equal(state.source:text('draft').kind, 'consumed')
    expect.equal(field:value(), 'draft', 'the draft precedes the callback')
    expect.equal(#running.native.events.reported - first, 1)
    expect.truthy(running.native.events.reported[first + 1].message:find 'testing/ui%-contract%-consumer')
    expect.truthy(running.native.events.reported[first + 1].message:find 'onChange')
    expect.truthy(running.native.events.reported[first + 1].message:find 'field change failure')
    first = #running.native.events.reported
    expect.equal(state.source:key({ code = lunette.keyCodes().enter }).kind, 'consumed')
    expect.equal(#running.native.events.reported - first, 1)
    expect.truthy(running.native.events.reported[first + 1].message:find 'testing/ui%-contract%-consumer')
    expect.truthy(running.native.events.reported[first + 1].message:find 'onSubmit')
    expect.truthy(running.native.events.reported[first + 1].message:find 'field submit failure')
    expect.equal(#testing.takeReports(), 0)
  end)

  test(
    'a live blur callback can destroy its region without recursion or retained focus targets',
    function(running, state)
      local region, blurCount = nil, 0
      region = state.panel:region(state.context, {
        id = 'recursive-blur',
        bounds = { x = 10, y = 160, width = 80, height = 30 },
        receiver = {
          key = function()
            return false
          end,
          text = function()
            return false
          end,
          onBlur = function()
            blurCount += 1
            expect.truthy(region:destroy(), 'the live blur callback releases its region')
            expect.falsy(region:destroy(), 'terminal control destruction is idempotent')
            error 'blur cleanup failure'
          end,
        },
      })
      running:clickControl(state.service, 'Contract controls', 'recursive-blur')
      local first = #running.native.events.reported
      state.panel:setVisible(false)
      expect.equal(blurCount, 1)
      expect.truthy(region.dead)
      expect.equal(#running.native.events.reported - first, 1)
      expect.truthy(state.panel:destroy())
      expect.truthy(state.field.dead, 'later focus targets are released')
      expect.falsy(state.panel:destroy())
      expect.equal(state.source:text('after cleanup').kind, 'unhandled')
      expect.equal(#testing.takeReports(), 0)
    end
  )
end

return regressions

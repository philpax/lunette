local testing = require '@testing'
local uiHost = require '@lunette-contracts/ui-host'
local fixture = require '@testing/ui-host'
local registry = require '../private/registry'
local chord = require '../private/chord'
local expect = testing.expect
local test = testing.suite()

local element = uiHost.element

local function button(activations: { number }): uiHost.Element
  return element('test/column', {
    padding = 0.01,
    element('test/button', {
      key = 'go',
      onActivate = function()
        activations[1] += 1
      end,
      element('test/leaf', { width = 0.04, height = 0.02 }),
    }),
  })
end

test('an override wraps the kind beneath it and default appearance bypasses it', function()
  local overridden = 0
  local effect: any
  local state = fixture.boot {
    setup = function(service: uiHost.Service, owner: any)
      fixture.registerKinds(service, owner, {})
      effect = service:overrideKind(owner, 'test/button', {
        name = 'test/button',
        event = function(node: uiHost.Node, event: uiHost.Event, base: (uiHost.Node, uiHost.Event) -> ())
          if event.kind == 'activate' then
            overridden += 1
          end
          base(node, event)
        end,
      })
    end,
  }
  local activations = { 0 }
  fixture.show(state, button(activations))
  fixture.click(state, 'go')
  expect.equal(overridden, 1, 'the override sees the activation')
  expect.equal(activations[1], 1, 'the base registration still activates through base')

  state.service:setDefaultAppearance(true)
  expect.truthy(state.service:defaultAppearance(), 'default appearance is on')
  state.fixture:step()
  fixture.click(state, 'go')
  expect.equal(overridden, 1, 'default appearance bypasses the override')
  expect.equal(activations[1], 2, 'the base registration activates')

  state.service:setDefaultAppearance(false)
  state.fixture:step()
  fixture.click(state, 'go')
  expect.equal(overridden, 2, 'leaving default appearance restores the override')

  effect:dispose()
  state.fixture:step()
  fixture.click(state, 'go')
  expect.equal(overridden, 2, 'a disposed override no longer applies')
  expect.equal(activations[1], 4, 'the base registration remains')
  state.fixture:close()
end)

test('an override names a registered kind and keeps its name', function()
  local state = fixture.boot {
    setup = function(service: uiHost.Service, owner: any)
      fixture.registerKinds(service, owner, {})
    end,
  }
  local ok = pcall(function()
    state.service:overrideKind(state.owner, 'test/absent', { name = 'test/absent' })
  end)
  expect.falsy(ok, 'an override of an unregistered kind is refused')
  ok = pcall(function()
    state.service:overrideKind(state.owner, 'test/button', { name = 'test/other' })
  end)
  expect.falsy(ok, 'an override that renames the kind is refused')
  state.fixture:close()
end)

test('an override expansion reaches the expansion beneath it', function()
  local state = fixture.boot {
    setup = function(service: uiHost.Service, owner: any)
      fixture.registerKinds(service, owner, {})
      service:overrideKind(owner, 'test/counter', {
        name = 'test/counter',
        expand = function(
          props: uiHost.Props,
          children: { read [number]: uiHost.Element },
          state: { read [string]: any },
          actions: uiHost.Actions,
          base: uiHost.Expand?
        ): uiHost.Child
          return element('test/column', { key = 'wrapped', (assert(base))(props, children, state, actions) })
        end,
      })
    end,
  }
  fixture.show(state, element('test/column', { element('test/counter', { key = 'counter' }) }))
  expect.truthy(state.panel:find 'counter/wrapped/increment/label', 'the base expansion is inside the override')
  state.fixture:close()
end)

test('default appearance uses the base theme and keeps text scale', function()
  local state = fixture.boot {
    setup = function(service: uiHost.Service, owner: any)
      fixture.registerKinds(service, owner, {})
    end,
  }
  state.service:setMode 'light'
  state.service:setAccessibility { textScale = 1.5 }
  local scaled = state.service:theme().type.body.size
  state.service:setDefaultAppearance(true)
  local theme = state.service:theme()
  expect.equal(theme.mode, 'dark', 'the base theme is dark')
  expect.equal(theme.type.body.size, scaled, 'text scale still applies')
  state.service:setDefaultAppearance(false)
  expect.equal(state.service:theme().mode, 'light', 'the configured mode returns')
  state.fixture:close()
end)

test('default appearance resolves each visual name to its base visual', function()
  local target = registry.new({} :: any)
  local function first(): () end
  local function second(): () end
  registry.addVisual(target, {} :: any, 'test/visual', first)
  registry.addVisual(target, {} :: any, 'test/visual', second)
  expect.equal(#registry.visuals(target, 'test/visual'), 2, 'both visuals stack')
  expect.equal(#registry.overridden(target), 1, 'the second visual is reported as an override')
  target.defaultAppearance = true
  local visuals = registry.visuals(target, 'test/visual')
  expect.equal(#visuals, 1, 'only the base visual applies')
  expect.equal(visuals[1], first, 'the base visual is the first registered')
end)

test('an override outlives its base and applies again when the kind is registered again', function()
  local target = registry.new({} :: any)
  local remove = registry.addKind(target, {} :: any, { name = 'test/kind', visuals = { 'a' } })
  registry.overrideKind(target, {} :: any, 'test/kind', { name = 'test/kind', visuals = { 'b' } })
  expect.equal(registry.kind(target, 'test/kind').registration.visuals[1], 'b', 'the override is current')
  remove()
  expect.equal(registry.kind(target, 'test/kind'), target.missing, 'the kind is missing without its base')
  registry.addKind(target, {} :: any, { name = 'test/kind', visuals = { 'c' }, clip = true })
  local current = registry.kind(target, 'test/kind').registration
  expect.equal(current.visuals[1], 'b', 'the override applies to the new base')
  expect.truthy(current.clip, 'fields the override omits come from the new base')
end)

test('the chord fires once per hold of both thumbstick clicks', function()
  local state = chord.new()
  expect.falsy(chord.step(state, true, false, 2), 'one click alone does not fire')
  expect.falsy(chord.step(state, true, true, chord.HOLD / 2), 'a short hold does not fire')
  expect.truthy(chord.step(state, true, true, chord.HOLD / 2), 'the full hold fires')
  expect.falsy(chord.step(state, true, true, chord.HOLD), 'holding longer does not fire again')
  expect.falsy(chord.step(state, false, true, 0.1), 'releasing resets the chord')
  expect.falsy(chord.step(state, true, true, chord.HOLD * 0.9), 'a new hold starts over')
  expect.truthy(chord.step(state, true, true, chord.HOLD * 0.2), 'and fires when complete')
end)

return test

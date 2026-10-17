local testing = require '@testing'
local uiHost = require '@lunette-contracts/ui-host'
local registry = require '../private/registry'

local expect = testing.expect
local test = testing.suite()

local NAME = 'test/registered'

test('kind lookups keep their identities between registration changes', function()
  local target = registry.new({} :: any)
  local owner = {} :: any
  local removeBase = registry.addKind(target, owner, { name = NAME })
  local base = registry.kind(target, NAME)
  expect.equal(registry.kind(target, NAME), base, 'the base lookup is stable')
  expect.equal(registry.kind(target, 'test/absent'), target.missing, 'an absent kind uses the missing registration')

  local removeOverride = registry.overrideKind(target, owner, NAME, { name = NAME, clip = true })
  local current = registry.kind(target, NAME)
  expect.truthy(current ~= base, 'an override has its own identity')
  expect.equal(registry.kind(target, NAME), current, 'the overridden lookup is stable')
  target.defaultAppearance = true
  expect.equal(registry.kind(target, NAME), base, 'default appearance keeps the original base')
  target.defaultAppearance = false
  expect.equal(registry.kind(target, NAME), current, 'returning to overrides keeps the resolved identity')

  removeOverride()
  expect.equal(registry.kind(target, NAME), base, 'removing the last override restores the original base')
  removeBase()
  expect.equal(registry.kind(target, NAME), target.missing, 'removing the base leaves the kind missing')
end)

test('removing a middle override rebuilds the event and expansion bases above it', function()
  local target = registry.new({} :: any)
  local owner = {} :: any
  local log: { string } = {}
  registry.addKind(target, owner, {
    name = NAME,
    layout = { kind = 'container' },
    clip = false,
    event = function(node: uiHost.Node, event: uiHost.Event, base: (uiHost.Node, uiHost.Event) -> ()): ()
      table.insert(log, 'base event')
      base(node, event)
    end,
    expand = function(): uiHost.Child
      table.insert(log, 'base expand')
      return uiHost.element 'test/output'
    end,
  })
  local function override(label: string, clip: boolean?): uiHost.KindRegistration
    return {
      name = NAME,
      clip = clip,
      event = function(node: uiHost.Node, event: uiHost.Event, base: (uiHost.Node, uiHost.Event) -> ()): ()
        table.insert(log, `{label} event`)
        base(node, event)
      end,
      expand = function(
        props: uiHost.Props,
        children: { read [number]: uiHost.Element },
        state: { read [string]: any },
        actions: uiHost.Actions,
        base: uiHost.Expand?
      ): uiHost.Child
        table.insert(log, `{label} expand`)
        return assert(base)(props, children, state, actions)
      end,
    }
  end
  registry.overrideKind(target, owner, NAME, override 'first')
  local removeMiddle = registry.overrideKind(target, owner, NAME, override('middle', true))
  registry.overrideKind(target, owner, NAME, override 'last')
  local before = registry.kind(target, NAME)
  assert(before.registration.event)({} :: any, { kind = 'activate', source = 'programmatic' }, function(): ()
    table.insert(log, 'host event')
  end)
  assert(before.registration.expand)({}, {}, {}, {} :: any)
  expect.equal(
    table.concat(log, ', '),
    'last event, middle event, first event, base event, host event, last expand, middle expand, first expand, base expand',
    'every layer reaches the registration beneath it'
  )
  expect.truthy(before.registration.clip, 'the middle override supplies a field')

  removeMiddle()
  local current = registry.kind(target, NAME)
  expect.truthy(current ~= before, 'removing a layer changes the resolved identity')
  expect.equal(registry.kind(target, NAME), current, 'the rebuilt identity is stable')
  expect.falsy(current.registration.clip, 'the removed field falls back to the base')
  expect.equal(#registry.overridden(target), 2, 'the other override declarations remain')
  table.clear(log)
  assert(current.registration.event)({} :: any, { kind = 'activate', source = 'programmatic' }, function(): ()
    table.insert(log, 'host event')
  end)
  local output = assert(current.registration.expand)({}, {}, {}, {} :: any) :: uiHost.Element
  expect.equal(output.kind, 'test/output', 'the base expansion still provides the output')
  expect.equal(
    table.concat(log, ', '),
    'last event, first event, base event, host event, last expand, first expand, base expand',
    'the later closures reach only the remaining layers'
  )
end)

test('an old base cleanup cannot remove its replacement', function()
  local target = registry.new({} :: any)
  local owner = {} :: any
  local removeBase = registry.addKind(target, owner, { name = NAME })
  local removeOverride = registry.overrideKind(target, owner, NAME, { name = NAME, clip = true })
  removeBase()
  expect.equal(registry.kind(target, NAME), target.missing, 'an override does not replace a missing base')
  local removeReplacement = registry.addKind(target, owner, { name = NAME, elevation = 0.01 })
  local current = registry.kind(target, NAME)
  expect.truthy(current.registration.clip, 'the waiting override applies to the replacement')
  expect.equal(current.registration.elevation, 0.01, 'the replacement supplies inherited fields')
  removeBase()
  expect.equal(registry.kind(target, NAME), current, 'a stale cleanup leaves the replacement unchanged')
  removeOverride()
  local replacement = registry.kind(target, NAME)
  expect.falsy(replacement.registration.clip, 'removing the waiting override restores the replacement base')
  expect.equal(replacement.registration.elevation, 0.01, 'the replacement base survives override cleanup')
  removeReplacement()
  expect.equal(registry.kind(target, NAME), target.missing, 'the replacement has its own cleanup')
end)

test('a skipped override stays registered and can apply to a later base', function()
  local target = registry.new({} :: any)
  local baseOwner, skippedOwner, lastOwner = {} :: any, {} :: any, {} :: any
  registry.overrideKind(target, skippedOwner, NAME, {
    name = NAME,
    expand = function(): uiHost.Child
      return uiHost.element 'test/output'
    end,
  })
  registry.overrideKind(target, lastOwner, NAME, { name = NAME, clip = true })
  local removeBase, skipped = registry.addKind(target, baseOwner, { name = NAME, visuals = { 'test/visual' } })
  expect.equal(#skipped, 1, 'the incompatible expansion is skipped')
  expect.equal(skipped[1].owner, skippedOwner, 'the failure keeps the skipped owner')
  local current = registry.kind(target, NAME)
  expect.equal(current.owner, lastOwner, 'a later compatible override remains current')
  expect.equal(current.registration.expand, nil, 'the invalid layer does not affect later layers')
  expect.truthy(current.registration.clip, 'the later compatible override applies')
  expect.equal(#registry.overridden(target), 2, 'inspection keeps both raw override declarations')
  removeBase()

  local _, laterSkipped = registry.addKind(target, baseOwner, { name = NAME, layout = { kind = 'container' } })
  expect.equal(#laterSkipped, 0, 'both overrides fit the replacement base')
  expect.truthy(registry.kind(target, NAME).registration.expand, 'the waiting expansion now applies')
  expect.equal(registry.kind(target, NAME).owner, lastOwner, 'the later override remains current')
end)

test('removing a layer skips later overrides that no longer fit the base', function()
  local target = registry.new({} :: any)
  local owner = {} :: any
  local removeBase = registry.addKind(target, owner, { name = NAME, visuals = { 'test/visual' } })
  local base = registry.kind(target, NAME)
  local removeContainer = registry.overrideKind(target, owner, NAME, { name = NAME, layout = { kind = 'container' } })
  registry.overrideKind(target, owner, NAME, {
    name = NAME,
    expand = function(): uiHost.Child
      return nil
    end,
  })
  expect.truthy(registry.kind(target, NAME).composite, 'the container permits a drawing composite')
  removeContainer()
  expect.equal(registry.kind(target, NAME), base, 'a now-invalid expansion falls back to the original base')
  expect.equal(#registry.overridden(target), 1, 'the invalid declaration stays registered')
  removeBase()
  local _, skipped = registry.addKind(target, owner, { name = NAME, layout = { kind = 'container' } })
  expect.equal(#skipped, 0, 'the expansion applies to a compatible replacement base')
  expect.truthy(registry.kind(target, NAME).composite, 'the waiting expansion is active again')
end)

test('host layout kinds use containers for non-text content', function()
  local target = registry.new({} :: any)
  expect.equal(registry.kind(target, 'lunette/portal').registration.layout.kind, 'container', 'a portal is a container')
  registry.validate { name = NAME, layout = { kind = 'container' } }
  expect.falsy(
    pcall(registry.validate, { name = NAME, layout = { kind = 'leaf' } }),
    'the removed host variant is rejected'
  )
end)

return test

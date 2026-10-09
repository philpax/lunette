local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local schema = require '@lunette-plugin/schema'
local fixture = require './support/vr-manager'
local suite = testing.suite()

local test = fixture.testCases(suite)

local function expectNoReports(context)
  local reports = testing.takeReports()
  expect.equal(#reports, 0, context .. ': ' .. table.concat(reports, '; '))
end

local function control(env, id)
  for _, description in env:description().controls do
    if description.id == id then
      return description
    end
  end
  return nil
end

local function generation(env, id)
  local entry = assert(env:entry(id), 'entry is installed: ' .. id)
  for _, instance in env.running.service:snapshot().instances do
    if instance.id == entry.instanceId then
      return assert(instance.generationId, 'entry has an active generation: ' .. id)
    end
  end
  error('entry is absent from the runtime snapshot: ' .. id)
end

local function catalogEntry(env, id)
  for _, entry in env.running.service:catalog() do
    if entry.id == id then
      return entry
    end
  end
  error('entry is absent from the session catalog: ' .. id)
end

local function selectCatalog(env, id)
  env:item('catalog-list', 'catalog/' .. id)
end

local function clickDisabled(env, id)
  local description = env:description()
  local bounds = assert(assert(control(env, id)).bounds)
  env.controls:click(description, bounds.x + bounds.width / 2, bounds.y + bounds.height / 2)
end

local function graphGeometry(env)
  local result = {}
  for _, item in assert(control(env, 'graph')).items do
    local bounds = assert(item.bounds)
    local route = {}
    for _, point in item.route or {} do
      route[#route + 1] = { x = point.x, y = point.y }
    end
    result[item.id] = {
      x = bounds.x,
      y = bounds.y,
      width = bounds.width,
      height = bounds.height,
      route = route,
    }
  end
  return result
end

local function sameGeometry(first, second)
  for id, bounds in first do
    local other = second[id]
    if
      not other
      or bounds.x ~= other.x
      or bounds.y ~= other.y
      or bounds.width ~= other.width
      or bounds.height ~= other.height
      or #bounds.route ~= #other.route
    then
      return false
    end
    for index, point in bounds.route do
      if point.x ~= other.route[index].x or point.y ~= other.route[index].y then
        return false
      end
    end
  end
  for id in second do
    if not first[id] then
      return false
    end
  end
  return true
end

local function editingEntry()
  local current
  local definition = plugin.consumer({
    name = 'vr-lifecycle-editor',
    schema = schema.object { title = schema.default(schema.string()) 'initial' },
    init = function(_context, settings)
      current = settings
    end,
  }).definition
  return { id = 'vr-lifecycle-editor', definition = definition }, function()
    return current
  end
end

test('manager minimum canvas toolbar changes generations and restores catalog entries', function()
  local activations, releases = 0, 0
  local definition = plugin.define {
    name = 'vr-lifecycle-consumer',
    init = function(context)
      activations += 1
      context:effect(function()
        return function()
          releases += 1
        end
      end)
    end,
  }
  local id = 'vr-lifecycle-consumer'
  local env = fixture.boot({ { id = id, definition = definition } }, {
    pixels = 800,
    width = 1,
    height = 0.59,
  })
  env:open()
  expect.equal(env:description().logicalHeight, 472, 'the complete workflow fits the minimum logical height')
  local initial = assert(env:entry(id))
  local firstGeneration = generation(env, id)
  env:click('graph', 'node/' .. initial.instanceId)
  expect.truthy(assert(control(env, 'disable')).enabled, 'the selected fixture is mutable')
  env:click 'disable'
  local disabled = assert(env:entry(id))
  expect.equal(disabled.state, 'inactive', 'Disable changes the actual runtime state')
  expect.falsy(disabled.enabled, 'Disable changes entry intent')
  expect.equal(disabled.instanceId, initial.instanceId, 'Disable retains the installed instance')
  expect.equal(releases, 1, 'Disable releases the activation effects')
  env:click 'enable'
  local enabled = assert(env:entry(id))
  expect.equal(enabled.state, 'active', 'Enable reactivates the actual entry')
  expect.truthy(enabled.enabled, 'Enable restores entry intent')
  expect.equal(activations, 2, 'Enable initializes another activation')
  local enabledGeneration = generation(env, id)
  expect.truthy(enabledGeneration ~= firstGeneration, 'Enable replaces the inactive generation')
  env:click 'reload'
  local reloaded = assert(env:entry(id))
  expect.equal(reloaded.state, 'active', 'Reload leaves the replacement active')
  expect.equal(reloaded.instanceId, initial.instanceId, 'Reload replaces a generation, not the session entry')
  expect.truthy(generation(env, id) ~= enabledGeneration, 'Reload replaces the active generation')
  expect.equal(activations, 3, 'Reload initializes the replacement')
  expect.equal(releases, 2, 'Reload releases the previous activation')
  env:click 'remove'
  expect.equal(env:entry(id), nil, 'Remove uninstalls the actual entry')
  expect.equal(releases, 3, 'Remove releases the replacement activation')
  expect.falsy(catalogEntry(env, id).installed, 'the removed source remains in the session catalog')
  env:click 'catalog'
  selectCatalog(env, id)
  expect.truthy(assert(control(env, 'load')).enabled, 'a removed catalog entry enables Load')
  env:click 'load'
  local restored = assert(env:entry(id))
  expect.equal(restored.state, 'active', 'Load activates the catalog source')
  expect.truthy(restored.enabled, 'Load installs an enabled entry')
  expect.truthy(restored.instanceId ~= initial.instanceId, 'Load registers a new runtime instance')
  expect.truthy(catalogEntry(env, id).installed, 'Load updates the actual catalog state')
  expect.equal(activations, 4, 'Load initializes the restored source')
  expect.falsy(assert(control(env, 'load')).enabled, 'the installed catalog entry cannot be loaded twice')
  env:close()
  expect.equal(releases, activations, 'every lifecycle activation releases its effects')
  expectNoReports 'the lifecycle workflow produces no reports'
end)

test('manager disables removal of every selected VR recovery dependency', function()
  local env = fixture.boot()
  env:open()
  for _ = 1, 8 do
    env:click 'zoom-out'
  end
  for _, id in { 'desktop/manager', 'desktop/menu', 'desktop/keyboard', 'desktop/pointing', 'ui' } do
    local entry = assert(env:entry(id))
    expect.truthy(entry.protected, id .. ' is needed by the VR recovery path')
    local before = generation(env, id)
    env:click('graph', 'node/' .. entry.instanceId)
    for _, action in { 'disable', 'reload', 'remove' } do
      expect.falsy(assert(control(env, action)).enabled, action .. ' is disabled for ' .. id)
      clickDisabled(env, action)
    end
    local retained = assert(env:entry(id))
    expect.equal(retained.state, 'active', 'disabled toolbar actions retain ' .. id)
    expect.equal(retained.instanceId, entry.instanceId, 'disabled actions cannot replace ' .. id)
    expect.equal(generation(env, id), before, 'disabled actions cannot replace the generation of ' .. id)
    expect.truthy(catalogEntry(env, id).installed, 'disabled Remove retains the installed catalog source')
  end
  env:click 'close'
  env:open()
  expect.truthy(env:description().visible, 'the protected wrist Plugins path still reopens the manager')
  env:close()
  expectNoReports 'disabled recovery actions produce no reports'
end)

test('manager Close cancels an edited field before wrist Plugins reopens it', function()
  local entry, current = editingEntry()
  local env = fixture.boot { entry }
  env:open()
  local initial = env:description()
  env:click('graph', 'node/' .. assert(env:entry(entry.id)).instanceId)
  env:click 'configure'
  env:click('rows', 'row/s:title')
  env:click 'edit-field'
  env:key 'All'
  env:key 'Text'
  expect.truthy(env.services.focus:focused(), 'the edited field owns the keyboard route')
  expect.truthy(env.services.display:isVisible(), 'the editor displays the shared keyboard')
  expect.equal(current().title, 'initial', 'unconfirmed text does not change the activation')
  env:click 'close'
  expect.falsy(env:description().visible, 'Close hides the manager during editing')
  expect.equal(env.services.focus:focused(), nil, 'Close releases the edited field route')
  expect.falsy(env.services.display:isVisible(), 'Close ends automatic keyboard visibility')
  env:open()
  expect.truthy(env:description().visible, 'wrist Plugins reopens the manager')
  expect.equal(env:description().generation, initial.generation, 'reopening retains the shared panel generation')
  expect.equal(control(env, 'edit-field'), nil, 'reopening has no stale edited field')
  expect.equal(env.services.focus:focused(), nil, 'reopening does not reclaim the old field route')
  expect.falsy(env.services.display:isVisible(), 'reopening does not restore automatic keyboard visibility')
  env:click('rows', 'row/s:title')
  env:click 'edit-field'
  env:click 'confirm'
  env:click 'apply'
  expect.equal(current().title, 'initial', 'Close cancels unconfirmed text instead of applying it on the next edit')
  env:close()
  expectNoReports 'closing an edited field produces no reports'
end)

test('manager Close cancels a captured graph pan before wrist Plugins reopens it', function()
  local env = fixture.boot()
  env:open()
  env:click 'fit'
  local initial = env:description()
  local geometry = graphGeometry(env)
  expect.truthy(next(geometry), 'the public graph exposes hit geometry')
  local bounds = assert(assert(control(env, 'graph')).bounds)
  local x, y = bounds.x + bounds.width / 2, bounds.y + bounds.height / 2
  env.controls:aim(initial, x, y, 'left')
  env.controls:step()
  env.controls:button('left', 'trigger', true)
  env.controls:step()
  env.controls:aim(env:description(), x + 16, y + 16, 'left')
  env.controls:step()
  env:click 'close'
  expect.falsy(env:description().visible, 'the other controller closes the manager during capture')
  env.controls:pose('left', lovr.math.newMat4():translate(0, 1.2, -0.5))
  env.controls:step()
  env:open()
  expect.truthy(env:description().visible, 'wrist Plugins reopens after capture cancellation')
  expect.equal(env:description().generation, initial.generation, 'capture cancellation retains the panel generation')
  expect.equal(env.services.focus:focused(), nil, 'the closed gesture leaves no focus route')
  expect.falsy(env.services.display:isVisible(), 'the closed gesture leaves no keyboard claim')
  local cancelled = graphGeometry(env)
  expect.truthy(next(cancelled), 'the cancelled graph still publishes geometry')
  expect.falsy(sameGeometry(cancelled, geometry), 'Close publishes the pan that happened before cancellation')
  env.controls:aim(env:description(), x + 48, y + 32, 'left')
  env.controls:step()
  expect.truthy(
    sameGeometry(graphGeometry(env), cancelled),
    'moving the still-held pointer cannot continue the closed pan'
  )
  env.controls:button('left', 'trigger', false)
  env.controls:step()
  expect.truthy(sameGeometry(graphGeometry(env), cancelled), 'the old release cannot continue the closed pan')
  env:click 'zoom-in'
  expect.falsy(sameGeometry(graphGeometry(env), cancelled), 'fresh toolbar input works after cancellation')
  env:close()
  expectNoReports 'closing a captured pan produces no reports'
end)

return suite

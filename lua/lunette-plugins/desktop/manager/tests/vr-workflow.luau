local testing = require '@testing'
local expect = testing.expect
local fixture = require './support/vr-manager'
local suite = testing.suite()
local function test(name, run)
  suite(name, function()
    local ok, message = pcall(run)
    local closed, failure = pcall(fixture.cleanup)
    if not ok then
      error(tostring(message) .. (if closed then '' else '; cleanup: ' .. tostring(failure)), 0)
    end
    if not closed then
      error(failure, 0)
    end
  end)
end

for _, provider in { 'built-in', 'substitute' } do
  test(provider .. ' manager complete VR workflow discovers shared widgets and closes field routes', function()
    local env = fixture.boot(provider)
    env:open()
    local initial = env:description()
    expect.truthy(initial.visible, 'Plugins opens the shared panel')
    local controls = {}
    for _, control in initial.controls do
      controls[control.id] = control
    end
    local _, close = env.controls:discover(env.services.ui, 'desktop/manager/titlebar', 'close')
    controls.close = close
    for _, id in
      {
        'graph',
        'zoom-in',
        'zoom-out',
        'fit',
        'search',
        'clear-filter',
        'clear-selection',
        'inspect',
        'catalog',
        'close',
      }
    do
      expect.truthy(controls[id], 'public geometry describes ' .. id)
    end
    env:click 'zoom-in'
    env:click 'zoom-out'
    env:click 'fit'
    local selected = assert(env:entry 'desktop/manager')
    env:click('graph', 'node/' .. selected.instanceId)
    env:click 'search'
    expect.truthy(env.services.display:isVisible(), 'Search opens the existing shared keyboard')
    expect.truthy(env.services.focus:focused(), 'a text field owns the route')
    expect.equal(env:keyboardCount(), 1, 'Search creates one actual keyboard')
    env:key 'Text'
    env:key 'Hide'
    expect.equal(env.services.focus:focused(), nil, 'keyboard user-hide releases only the field route')
    env:click 'search'
    expect.equal(env:keyboardCount(), 1, 'resuming Search reuses that keyboard')
    env:click 'clear-filter'
    env:click 'clear-selection'
    env:click 'close'
    expect.falsy(env:description().visible, 'Close hides the manager')
    expect.equal(env.services.focus:focused(), nil, 'Close blurs the field')
    expect.falsy(env.services.display:isVisible(), 'Close ends automatic keyboard visibility')
    env:open()
    expect.truthy(env:description().visible, 'Plugins reopens the same manager')
    expect.equal(env:description().generation, initial.generation, 'ordinary reopening retains the panel generation')
    env:close()
  end)
end

return suite

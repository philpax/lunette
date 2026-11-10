-- Covers lua/lunette-plugins/layout/persistence/private/properties.luau: one store for all panel families.

local testing = require '@testing'
local lunette = require '@lunette'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local frameContract = require '@lunette-contracts/frame'
local panelsContract = require '@lunette-contracts/panels'
local rulesContract = require '@lunette-contracts/rules'
local tagsContract = require '@lunette-contracts/tags'
local uiHost = require '@lunette-contracts/ui-host'
local versionedFile = require '@lunette-plugins/storage/versioned-file'
local persist = require '../private/state'
local properties = require '../private/properties'

local test = testing.suite()
local FILE = properties.FILE

type Environment = {
  native: testing.Native,
  session: testing.Session,
  state: persist.State,
  binding: any,
  context: testing.Context,
  panels: panelsContract.Service,
  host: uiHost.Service?,
  hostOwner: testing.Context?,
  connect: () -> (),
  disconnect: () -> (),
}

local ENTRIES =
  { 'theme', 'frame', 'surfaces', 'drops', 'focus', 'interaction', 'panels', 'tags', 'rules', 'placement' }

local function withStore(
  options: { storeText: string?, uiHost: boolean?, late: boolean? },
  run: (Environment) -> ()
): testing.Native
  local native = testing.native()
  if options.storeText then
    native.events.files[FILE] = options.storeText
  end
  local state = persist.new(persist.FILE)
  local entries: { any } = table.clone(ENTRIES)
  if options.uiHost then
    table.insert(entries, { id = 'ui-host', definition = require('@lunette-plugins/ui/host').definition })
  end
  local session = testing.boot(entries, { native = native })
  local observed = if options.uiHost then session:observe(uiHost.capability) else nil
  local connection: any = nil
  if observed and not options.late then
    connection = { service = observed.service, owner = observed.context }
  end
  local environment: Environment = nil :: any
  session:use(
    adapter.define {
      name = 'properties-test',
      requires = {
        panelsContract.capability,
        tagsContract.capability,
        rulesContract.capability,
        frameContract.capability,
      },
      init = function(context: testing.Context)
        local panels = context:require(panelsContract.capability)
        local binding = state:bind(
          context,
          panels,
          context:require(tagsContract.capability),
          context:require(rulesContract.capability),
          context:require(frameContract.capability),
          function(): any
            return connection
          end
        )
        environment = {
          native = native,
          session = session,
          state = state,
          binding = binding,
          context = context,
          panels = panels,
          host = if observed then observed.service else nil,
          hostOwner = if observed then observed.context else nil,
          connect = function(): ()
            if observed then
              connection = { service = observed.service, owner = observed.context }
            end
          end,
          disconnect = function(): ()
            connection = nil
          end,
        }
        run(environment)
      end,
    },
    {}
  )
  session:close()
  return native
end

local function readStore(native: testing.Native): { [string]: any }
  local text = native.events.files[FILE]
  if not text then
    return {}
  end
  local loaded = versionedFile.parse(text, FILE, properties.VERSION)
  expect.equal(loaded.kind, 'data', 'the store parses')
  return loaded.data
end

test('a native window restores its curve, input lock, and transform lock', function()
  local text = versionedFile.render({
    ['window/terminal/1'] = { curve = 0.5, curveAxis = 0, inputLocked = true, transformLocked = false },
  }, properties.VERSION)
  withStore({ storeText = text }, function(env: Environment)
    local panel = env.panels:fromWindow(env.context, env.native.newWindow(1))
    expect.near(panel.curve, 0.5, 1e-9, 'the stored curve restores')
    expect.truthy(panel.locked, 'the stored input lock restores')
    expect.falsy(panel.transformLocked, 'the stored transform lock restores')
  end)
end)

test('a native commit and a native transform toggle each write panel-properties.saved once', function()
  withStore({}, function(env: Environment)
    local panel = env.panels:fromWindow(env.context, env.native.newWindow(1))
    expect.truthy(panel:setCurve(0.5, true), 'the commit applies')
    expect.equal(env.native.events.fileWrites[FILE], 1, 'the commit writes the store')
    expect.truthy(panel:setCurve(0.7), 'the preview applies')
    expect.equal(env.native.events.fileWrites[FILE], 1, 'a preview writes nothing')
    expect.truthy(panel:setTransformLocked(env.context, true), 'the transform toggle applies')
    expect.equal(env.native.events.fileWrites[FILE], 2, 'the toggle writes the store')
    local data = readStore(env.native)
    local stored = data['window/terminal/1']
    expect.truthy(stored, 'the window entry is keyed by application id and slot')
    expect.near(stored.curve, 0.7, 1e-9, 'the store keeps the latest curve')
    expect.truthy(stored.transformLocked, 'the store keeps the transform lock')
    expect.equal(env.native.events.writes, 0, 'no arrangement write happened')
  end)
end)

test('a monitor restores from its key and slot', function()
  local text = versionedFile.render({
    ['monitor/screen-a/1'] = { curve = 0.25, curveAxis = 0, inputLocked = false, transformLocked = true },
  }, properties.VERSION)
  withStore({ storeText = text }, function(env: Environment)
    local monitor = env.panels:fromMonitor(env.context, env.native.newMonitor 'screen-a')
    expect.near(monitor.curve, 0.25, 1e-9, 'the monitor curve restores')
    expect.truthy(monitor.transformLocked, 'the monitor transform lock restores')
  end)
end)

test('two live panels for one monitor key get distinct ids and separate properties', function()
  withStore({}, function(env: Environment)
    local monitor = env.native.newMonitor 'screen-a'
    local first = env.panels:fromMonitor(env.context, monitor)
    local second = env.panels:fromMonitor(env.context, monitor)
    expect.truthy(first:setCurve(0.3, true), 'the first curving applies')
    expect.truthy(second:setCurve(0.6, true), 'the second curving applies')
    local data = readStore(env.native)
    expect.truthy(data['monitor/screen-a/1'], 'the first mirror has slot one')
    expect.truthy(data['monitor/screen-a/2'], 'the second mirror has slot two')
    expect.near(data['monitor/screen-a/1'].curve, 0.3, 1e-9, 'the first mirror keeps its curve')
    expect.near(data['monitor/screen-a/2'].curve, 0.6, 1e-9, 'the second mirror keeps its curve')
  end)
end)

test('a creator property wins over the store', function()
  local text = versionedFile.render({
    ['window/terminal/1'] = { curve = 0.5, curveAxis = 0, inputLocked = true, transformLocked = false },
  }, properties.VERSION)
  withStore({ storeText = text }, function(env: Environment)
    local panel = env.panels:fromWindow(env.context, env.native.newWindow(1), {
      curve = 0.9,
      locked = false,
      transformLocked = true,
    })
    expect.near(panel.curve, 0.9, 1e-9, 'the creator curve wins')
    expect.falsy(panel.locked, 'the creator input lock wins')
    expect.truthy(panel.transformLocked, 'the creator transform lock wins')
  end)
end)

test('a store from a later version is refused and left alone', function()
  local text = versionedFile.render({}, properties.VERSION + 1)
  local native = withStore({ storeText = text }, function(env: Environment)
    local saved, message = env.binding:save()
    expect.equal(saved, false, 'the save is refused')
    expect.truthy(message and message:find('written by version', 1, true), tostring(message))
    env.panels:fromWindow(env.context, env.native.newWindow(1))
    expect.equal(env.native.events.fileWrites[FILE], nil, 'no store write happens')
  end)
  expect.equal(native.events.files[FILE], text, 'the file is untouched')
end)

test('a save keeps the entries of panels that are no longer live', function()
  withStore({}, function(env: Environment)
    local firstWindow = env.native.newWindow(1, 'terminal')
    local first = env.panels:fromWindow(env.context, firstWindow)
    local second = env.panels:fromWindow(env.context, env.native.newWindow(2, 'browser'))
    first:setCurve(0.3, true)
    second:setCurve(0.6, true)
    first:destroy(env.context)
    second:setCurve(0.4, true)
    local data = readStore(env.native)
    expect.truthy(data['window/terminal/1'], 'the closed application keeps its entry')
    expect.truthy(data['window/browser/1'], 'the live panel keeps its entry')
  end)
end)

test('native properties persist with no ui-host', function()
  withStore({}, function(env: Environment)
    expect.equal(env.host, nil, 'no toolkit host is present')
    local panel = env.panels:fromWindow(env.context, env.native.newWindow(1))
    panel:setLocked(env.context, true)
    expect.equal(env.native.events.fileWrites[FILE], 1, 'the native lock writes the store')
  end)
end)

test('a store bound before the ui-host appears restores and persists toolkit properties', function()
  withStore({ uiHost = true, late = true }, function(env: Environment)
    local host = assert(env.host)
    local panel = host:newPanel(assert(env.hostOwner), { name = 'late-panel', width = 0.3, height = 0.2 })
    panel:setCurve(0.4, 0, true)
    env.session:update()
    expect.equal(env.native.events.fileWrites[FILE], nil, 'no store is connected yet')
    env.connect()
    env.session:update()
    expect.near(panel:curve(), 0.4, 1e-9, 'the curve survives the connection')
    panel:setCurve(0.2, 0, true)
    expect.equal(env.native.events.fileWrites[FILE], 1, 'a change writes the store once connected')
    local data = readStore(env.native)
    expect.near(data['toolkit/late-panel'].curve, 0.2, 1e-9, 'the toolkit entry is keyed by name')
    panel:destroy()
  end)
end)

test('an attached, dialog, or follow toolkit panel receives no properties entry', function()
  withStore({ uiHost = true }, function(env: Environment)
    local host = assert(env.host)
    env.session:update()
    local owner = assert(env.hostOwner)
    local target = host:newPanel(owner, { name = 'world', width = 0.3, height = 0.2 })
    local attached = host:newPanel(owner, {
      name = 'attached',
      presentation = 'attach',
      target = { dead = false, width = 0.3, height = 0.2 } :: any,
      height = 0.05,
    })
    local dialog = host:newPanel(owner, {
      name = 'dialog',
      presentation = 'dialog',
      width = 0.2,
      height = 0.1,
    })
    local follow = host:newPanel(owner, {
      name = 'follow',
      presentation = 'follow',
      width = 0.2,
      height = 0.1,
    })
    for _, panel in { attached, dialog, follow } do
      panel:setCurve(0.3, 0, true)
    end
    target:setCurve(0.5, 0, true)
    local data = readStore(env.native)
    expect.truthy(data['toolkit/world'], 'the world panel has an entry')
    expect.equal(data['toolkit/attached'], nil, 'the attached titlebar has no entry')
    expect.equal(data['toolkit/dialog'], nil, 'the dialog has no entry')
    expect.equal(data['toolkit/follow'], nil, 'the follow panel has no entry')
    for _, panel in { attached, dialog, follow, target } do
      panel:destroy()
    end
  end)
end)

test('a store from a later version refuses the arrangement save', function()
  local text = versionedFile.render({}, properties.VERSION + 1)
  local native = withStore({ storeText = text }, function(env: Environment)
    local saved, message = env.binding:save()
    expect.equal(saved, false, 'the arrangement is not saved without its properties')
    expect.truthy(message and message:find('panel properties', 1, true), tostring(message))
  end)
  expect.equal(native.events.writes, 0, 'the arrangement file is untouched')
end)

test('a toolkit creator property wins over the store', function()
  local text = versionedFile.render({
    ['toolkit/explicit-panel'] = { curve = 0.5, curveAxis = 0, inputLocked = true, transformLocked = false },
  }, properties.VERSION)
  withStore({ storeText = text, uiHost = true }, function(env: Environment)
    env.session:update()
    local host = assert(env.host)
    local panel = host:newPanel(assert(env.hostOwner), {
      name = 'explicit-panel',
      width = 0.3,
      height = 0.2,
      curve = 0.9,
      locked = false,
      transformLocked = true,
    })
    expect.near(panel:curve(), 0.9, 1e-9, 'the creator curve wins')
    expect.falsy(panel:locked(), 'the creator input lock wins')
    expect.truthy(panel:transformLocked(), 'the creator transform lock wins')
    panel:destroy()
  end)
end)

test('a provider restart restores native properties and keeps saving', function()
  local native = testing.native()
  local state = persist.new(persist.FILE)
  local session = testing.boot(ENTRIES, { native = native })
  local panels, owner
  session:use(
    adapter.define {
      name = 'properties-panels-owner',
      requires = { panelsContract.capability },
      init = function(context: testing.Context)
        panels = context:require(panelsContract.capability)
        owner = context
      end,
    },
    {}
  )
  local panel
  local function bind(context: testing.Context): ()
    state:bind(
      context,
      panels,
      context:require(tagsContract.capability),
      context:require(rulesContract.capability),
      context:require(frameContract.capability),
      nil
    )
  end
  local first = session:use(
    adapter.define {
      name = 'properties-first',
      requires = {
        panelsContract.capability,
        tagsContract.capability,
        rulesContract.capability,
        frameContract.capability,
      },
      init = function(context: testing.Context)
        bind(context)
        panel = panels:fromWindow(owner, native.newWindow(1))
        panel:setCurve(0.5, true)
        panel:setCurve(0.2)
        expect.near(panel.curve, 0.2, 1e-9, 'the preview changes the panel without saving')
      end,
    },
    {}
  )
  first:disable()
  session:use(
    adapter.define {
      name = 'properties-second',
      requires = {
        panelsContract.capability,
        tagsContract.capability,
        rulesContract.capability,
        frameContract.capability,
      },
      init = function(context: testing.Context)
        bind(context)
        expect.near(panel.curve, 0.5, 1e-9, 'the stored value returns on the restart')
        panel:setCurve(0.6, true)
        expect.truthy(native.events.fileWrites[FILE] >= 2, 'the restarted store keeps saving')
      end,
    },
    {}
  )
  session:close()
end)

test('a provider restart restores toolkit properties', function()
  local native = testing.native()
  local state = persist.new(persist.FILE)
  local entries: { any } = table.clone(ENTRIES)
  table.insert(entries, { id = 'ui-host', definition = require('@lunette-plugins/ui/host').definition })
  local session = testing.boot(entries, { native = native })
  local observed = session:observe(uiHost.capability)
  local panel
  local function bind(context: testing.Context): ()
    state:bind(
      context,
      context:require(panelsContract.capability),
      context:require(tagsContract.capability),
      context:require(rulesContract.capability),
      context:require(frameContract.capability),
      function(): any
        return { service = observed.service, owner = observed.context }
      end
    )
  end
  local first = session:use(
    adapter.define {
      name = 'properties-toolkit-first',
      requires = {
        panelsContract.capability,
        tagsContract.capability,
        rulesContract.capability,
        frameContract.capability,
      },
      init = function(context: testing.Context)
        bind(context)
        session:update()
        panel = observed.service:newPanel(observed.context, { name = 'restart-panel', width = 0.3, height = 0.2 })
        panel:setCurve(0.5, 0, true)
        panel:setCurve(0.2, 0, false)
        expect.near(panel:curve(), 0.2, 1e-9, 'the toolkit preview applies without saving')
      end,
    },
    {}
  )
  first:disable()
  session:use(
    adapter.define {
      name = 'properties-toolkit-second',
      requires = {
        panelsContract.capability,
        tagsContract.capability,
        rulesContract.capability,
        frameContract.capability,
      },
      init = function(context: testing.Context)
        bind(context)
        expect.near(panel:curve(), 0.5, 1e-9, 'the toolkit value returns on the restart')
      end,
    },
    {}
  )
  panel:destroy()
  session:close()
end)

test('a store failure at save time is reported and does not write the arrangement', function()
  withStore({}, function(env: Environment)
    env.panels:fromWindow(env.context, env.native.newWindow(1))
    env.native.events.saveFailure = 'the fixture refuses the store'
    local saved, message = env.binding:save()
    expect.equal(saved, false, 'the save is refused')
    expect.truthy(message and message:find('panel properties', 1, true), tostring(message))
    expect.truthy(message and message:find('the fixture refuses the store', 1, true), tostring(message))
    expect.equal(env.native.events.writes, 0, 'the arrangement is not written')
  end)
end)

test('the persistence provider activates with its dependencies', function()
  local native = testing.native()
  local session =
    testing.start { 'theme', 'frame', 'panels', 'tags', 'rules', 'drops', 'placement', 'desktop/persistence' }
  local observed = session:observe(require('@lunette-contracts/arrangement').capability)
  expect.truthy(observed.service, 'the persistence service is present')
  session:close()
end)

return test

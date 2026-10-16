local testing = require '@testing'
local adapter = require '@lunette-plugin/adapter'
local schema = require '@lunette-plugin/schema'
local uiHost = require '@lunette-contracts/ui-host'
local fixture = require '@testing/ui-host'
local expect = testing.expect
local test = testing.suite()

local element = uiHost.element

local SETTINGS = uiHost.outlet {
  name = 'test/settings',
  version = { major = 1, minor = 1 },
  props = schema.object { entry = schema.string() },
}

local ATTRIBUTED = uiHost.outlet {
  name = 'test/attributed',
  version = { major = 1, minor = 0 },
  props = schema.object { entry = schema.string() },
  attributed = true,
}

type Log = { string }

-- A contribution that shows a text with the entry it is given, and logs its binds, renders, and unmounts.
local function showing(log: Log, name: string, version: uiHost.Version?): uiHost.Contribution
  return {
    version = version,
    bind = function(mount: uiHost.OutletMount): ()
      table.insert(log, `{name}:bind`)
      mount:bind {
        render = function(): ()
          local props = mount:props()
          table.insert(log, `{name}:render {props.entry}`)
          mount:submit(element('test/text', { key = 'content', text = `{name} {props.entry}` }))
        end,
        unmount = function(): ()
          table.insert(log, `{name}:unmount`)
        end,
      }
    end,
  }
end

-- A plugin that contributes to an outlet from its own context, so its definition name attributes the contribution.
local function contributor(name: string, outlet: uiHost.Outlet<any>, contribution: uiHost.Contribution): any
  return adapter.define {
    name = name,
    requires = { uiHost.capability },
    init = function(context: adapter.Context): ()
      context:require(uiHost.capability):contribute(context, outlet, contribution)
    end,
  }
end

local function boot(plugins: { any }?): fixture.State
  return fixture.boot {
    plugins = plugins,
    setup = function(service: uiHost.Service, owner: any): ()
      fixture.registerKinds(service, owner, {})
    end,
  }
end

local function place(outlet: uiHost.Outlet<any>, entry: string, key: string?): uiHost.Element
  return element('lunette/outlet', { key = key or 'outlet', outlet = outlet, props = { entry = entry } })
end

local function text(state: fixture.State, path: string): string?
  local node = state.panel:find(path)
  return if node then node.props.text else nil
end

local function count(log: Log, entry: string): number
  local total = 0
  for _, line in log do
    if line == entry then
      total += 1
    end
  end
  return total
end

local function takeReports(state: fixture.State): { string }
  local reported = assert(state.fixture.native).events.reported
  local messages: { string } = {}
  for index, report in reported do
    messages[index] = report.message
  end
  table.clear(reported)
  return messages
end

local function reportedWith(messages: { string }, fragment: string): boolean
  for _, message in messages do
    if string.find(message, fragment, 1, true) then
      return true
    end
  end
  return false
end

local ALPHA = uiHost.keyOf 'test/alpha'
local BETA = uiHost.keyOf 'test/beta'

test('a contribution renders with the placement props and renders again when they change', function()
  local log: Log = {}
  local state = boot { contributor('test/alpha', SETTINGS, showing(log, 'alpha')) }
  fixture.show(state, element('test/column', { place(SETTINGS, 'first') }))
  expect.equal(text(state, `outlet/{ALPHA}/content`), 'alpha first', 'the contribution renders in the same commit')
  fixture.show(state, element('test/column', { place(SETTINGS, 'second') }))
  expect.equal(text(state, `outlet/{ALPHA}/content`), 'alpha second', 'new props reach the contribution')
  expect.equal(count(log, 'alpha:bind'), 1, 'the instance is kept across prop changes')
  state.fixture:close()
end)

test('contributions render in the order of their contributors, whatever order they arrived in', function()
  local log: Log = {}
  local state = boot {
    contributor('test/beta', SETTINGS, showing(log, 'beta')),
    contributor('test/alpha', SETTINGS, showing(log, 'alpha')),
  }
  fixture.show(state, element('test/column', { place(SETTINGS, 'one') }))
  local alpha = assert(state.panel:find(`outlet/{ALPHA}`)):panelBounds()
  local beta = assert(state.panel:find(`outlet/{BETA}`)):panelBounds()
  expect.truthy(alpha.y < beta.y, 'alpha is above beta')
  state.fixture:close()
end)

test('an ordering function decides the order of contributions', function()
  local log: Log = {}
  local reversed = uiHost.outlet {
    name = 'test/reversed',
    version = { major = 1, minor = 0 },
    props = schema.object { entry = schema.string() },
    order = function(first: uiHost.OutletEntry, second: uiHost.OutletEntry): boolean
      return first.contributor > second.contributor
    end,
  }
  local state = boot {
    contributor('test/alpha', reversed, showing(log, 'alpha')),
    contributor('test/beta', reversed, showing(log, 'beta')),
  }
  fixture.show(state, element('test/column', { place(reversed, 'one') }))
  local alpha = assert(state.panel:find(`outlet/{ALPHA}`)):panelBounds()
  local beta = assert(state.panel:find(`outlet/{BETA}`)):panelBounds()
  expect.truthy(beta.y < alpha.y, 'beta is above alpha')
  state.fixture:close()
end)

test('each placement of an outlet is a separate instance', function()
  local log: Log = {}
  local state = boot { contributor('test/alpha', SETTINGS, showing(log, 'alpha')) }
  fixture.show(state, element('test/column', { place(SETTINGS, 'left', 'left'), place(SETTINGS, 'right', 'right') }))
  expect.equal(count(log, 'alpha:bind'), 2, 'the contribution binds once for each placement')
  expect.equal(text(state, `left/{ALPHA}/content`), 'alpha left')
  expect.equal(text(state, `right/{ALPHA}/content`), 'alpha right')
  fixture.show(state, element('test/column', { place(SETTINGS, 'left', 'left'), place(SETTINGS, 'moved', 'right') }))
  expect.equal(count(log, 'alpha:render left'), 1, 'an unchanged placement does not render again')
  expect.equal(text(state, `right/{ALPHA}/content`), 'alpha moved')
  fixture.show(state, element('test/column', { place(SETTINGS, 'left', 'left') }))
  expect.equal(count(log, 'alpha:unmount'), 1, 'removing a placement unmounts its instance alone')
  state.fixture:close()
end)

test('a contribution built against a higher minor or another major version is rejected', function()
  local log: Log = {}
  local state = boot()
  local function contribute(version: uiHost.Version): ()
    state.service:contribute(state.owner, SETTINGS, showing(log, 'late', version))
  end
  local ok, problem = pcall(contribute, { major = 1, minor = 2 })
  expect.falsy(ok, 'a higher minor version is rejected')
  expect.truthy(string.find(tostring(problem), 'version 1.2', 1, true), tostring(problem))
  expect.falsy((pcall(contribute, { major = 2, minor = 0 })), 'another major version is rejected')
  contribute { major = 1, minor = 0 }
  fixture.show(state, element('test/column', { place(SETTINGS, 'accepted') }))
  expect.equal(count(log, 'late:render accepted'), 1, 'a lower minor version is accepted')
  state.fixture:close()
end)

test('a placement of an older version skips a newer contribution and reports it against the contributor', function()
  local log: Log = {}
  local older = uiHost.outlet {
    name = 'test/settings',
    version = { major = 1, minor = 0 },
    props = schema.object { entry = schema.string() },
  }
  local state = boot { contributor('test/alpha', SETTINGS, showing(log, 'alpha')) }
  fixture.show(state, element('test/column', { place(older, 'old') }))
  expect.equal(state.panel:find(`outlet/{ALPHA}`), nil, 'the contribution does not render')
  local messages = takeReports(state)
  expect.truthy(reportedWith(messages, 'contribution from test/alpha'), 'the report names the contributor')
  expect.truthy(reportedWith(messages, 'built against version 1.1'), 'the report names the versions')
  state.fixture:close()
end)

test('a second declaration of a name and version with another schema is rejected', function()
  local log: Log = {}
  local conflicting = uiHost.outlet {
    name = 'test/settings',
    version = { major = 1, minor = 1 },
    props = schema.object { entry = schema.number() },
  }
  local same = uiHost.outlet {
    name = 'test/settings',
    version = { major = 1, minor = 1 },
    props = schema.object { entry = schema.string() },
  }
  local state = boot { contributor('test/alpha', SETTINGS, showing(log, 'alpha')) }
  local ok, problem = pcall(function(): ()
    state.service:contribute(state.owner, conflicting, showing(log, 'conflict'))
  end)
  expect.falsy(ok, 'the contribution is rejected')
  expect.truthy(string.find(tostring(problem), 'another schema', 1, true), tostring(problem))
  state.service:contribute(state.owner, same, showing(log, 'same'))
  fixture.show(state, element('test/column', { place(conflicting, 'one', 'wrong'), place(same, 'two', 'right') }))
  expect.equal(state.panel:find(`wrong/{ALPHA}`), nil, 'a conflicting placement renders no contributions')
  expect.truthy(reportedWith(takeReports(state), 'another schema'), 'the conflicting placement is reported')
  expect.equal(text(state, `right/{ALPHA}/content`), 'alpha two', 'an equal declaration places the outlet')
  state.fixture:close()
end)

test('an error in a contribution is reported against it and leaves the rest of the panel rendering', function()
  local log: Log = {}
  local failing: uiHost.Contribution = {
    bind = function(mount: uiHost.OutletMount): ()
      mount:bind {
        render = function(): ()
          error 'deliberate contribution failure'
        end,
      }
    end,
  }
  local state = boot {
    contributor('test/alpha', SETTINGS, showing(log, 'alpha')),
    contributor('test/beta', SETTINGS, failing),
  }
  fixture.show(
    state,
    element('test/column', { element('test/text', { key = 'own', text = 'own content' }), place(SETTINGS, 'one') })
  )
  local messages = takeReports(state)
  expect.truthy(reportedWith(messages, 'deliberate contribution failure'), 'the failure is reported')
  expect.truthy(reportedWith(messages, 'contribution from test/beta'), 'the report names the contributor')
  expect.equal(text(state, 'own'), 'own content', 'the outlet owner keeps its content')
  expect.equal(text(state, `outlet/{ALPHA}/content`), 'alpha one', 'the other contribution renders')
  state.fixture:close()
end)

test('a contribution ends when its owner ends, and the outlet renders without it', function()
  local log: Log = {}
  local state = boot()
  local instance = assert(state.fixture.session):use(contributor('test/alpha', SETTINGS, showing(log, 'alpha')))
  fixture.show(state, element('test/column', { place(SETTINGS, 'one') }))
  expect.equal(text(state, `outlet/{ALPHA}/content`), 'alpha one')
  instance:disable()
  expect.equal(count(log, 'alpha:unmount'), 1, 'the instance unmounts with its owner')
  state.fixture:step()
  expect.equal(state.panel:find(`outlet/{ALPHA}`), nil, 'the contribution is removed')
  instance:enable()
  state.fixture:step()
  expect.equal(text(state, `outlet/{ALPHA}/content`), 'alpha one', 'a reloaded owner contributes again')
  state.fixture:close()
end)

test('an attributed outlet frames each contribution with its contributor and clips it to the outlet', function()
  local tall: uiHost.Contribution = {
    bind = function(mount: uiHost.OutletMount): ()
      mount:bind {
        render = function(): ()
          mount:submit(element('test/leaf', { key = 'content', width = 0.05, height = 0.5 }))
        end,
      }
    end,
  }
  local state = boot { contributor('test/alpha', ATTRIBUTED, tall) }
  fixture.show(
    state,
    element('test/column', {
      element('lunette/outlet', { key = 'outlet', outlet = ATTRIBUTED, props = { entry = 'one' }, maxHeight = 0.1 }),
    })
  )
  expect.equal(text(state, `outlet/{ALPHA}/attribution`), 'test/alpha', 'the frame names the contributing plugin')
  local frame = assert(state.panel:find(`outlet/{ALPHA}`))
  expect.equal(frame.kind, 'lunette/outlet-frame')
  expect.truthy(frame.bounds.height <= 0.1 + 1e-6, 'the frame keeps to the outlet maximum')
  expect.truthy(assert(state.panel:find(`outlet/{ALPHA}/body/content`)), 'the content sits in the body')
  local _, height = state.panel:size()
  expect.truthy(height < 0.2, 'the contribution does not push the panel open')
  state.fixture:close()
end)

test('inspection reports contributions and their owners', function()
  local log: Log = {}
  local state = boot { contributor('test/alpha', SETTINGS, showing(log, 'alpha')) }
  fixture.show(state, element('test/column', { place(SETTINGS, 'one', 'left'), place(SETTINGS, 'two', 'right') }))
  local found = nil
  for _, registration in state.service:inspect().registrations do
    if registration.kind == 'contribution' then
      found = registration
    end
  end
  local registration = assert(found, 'the contribution is listed')
  expect.equal(registration.name, 'test/settings')
  expect.equal(registration.details.contributor, 'test/alpha')
  expect.equal(registration.details.placements, 2)
  expect.equal(registration.details.version, '1.1')
  state.fixture:close()
end)

return test

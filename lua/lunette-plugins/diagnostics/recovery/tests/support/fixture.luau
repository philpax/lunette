-- Boots a managed composition with real pointing, a recording stand-in for the UI host and components, and the
-- recovery plugin, and clicks the recovery panel's actions with the right controller.

local testing = require '@testing'
local adapter = require '@lunette-plugin/adapter'
local plugin = require '@lunette-plugin'
local schema = require '@lunette-plugin/schema'
local management = require '@lunette-plugin/management'
local frameProvider = require '@lunette-plugins/session/frame'
local composition = require '@lunette-contracts/composition'
local surfaces = require '@lunette-contracts/surfaces'
local uiHost = require '@lunette-contracts/ui-host'
local uiComponents = require '@lunette-contracts/ui-components'
local vrUi = require '@testing/vr-ui'
local builtinEntries = require '@testing/builtin-entries'
local recovery = require '../../'
local layout = require '../../private/layout'

local fixture = {}

export type Settings = { value: number }

export type Environment = {
  saved: { overrides: { [string]: { [string]: unknown } } },
  native: testing.Native,
  controls: vrUi.Fixture,
  running: management.Running,
  composition: composition.Service,
  surfaces: surfaces.Service,
  -- The observer's context, which offers test surfaces.
  context: adapter.Context,
  host: { appearance: boolean, sets: number },
  -- The settings the configured test entry last started with.
  settings: { current: Settings? },
  panel: (Environment) -> any?,
  click: (Environment, layout.ActionId) -> (),
  step: (Environment, number?) -> (),
  draw: (Environment) -> (),
  entry: (Environment, string) -> composition.Entry?,
  close: (Environment) -> (),
}

local ORDER: { layout.ActionId } = { 'appearance', 'reload', 'restore', 'without-saved', 'safe-mode' }

-- The recovery settings the fixture boots with: short thresholds so cases run in a few frames.
fixture.CONFIG = {
  errorFrames = 3,
  quietFrames = 3,
  healthySeconds = 1,
  pollSeconds = 0,
}

local function standIns(host: { appearance: boolean, sets: number }): (adapter.Definition<{}>, adapter.Definition<{}>)
  local hostDefinition = plugin.provider<<{}, {}, uiHost.Service>>({
    name = 'test/ui-host',
    capability = uiHost.capability,
    build = function(_context: plugin.Context, _settings: {}): uiHost.Service
      return {
        setDefaultAppearance = function(_self: uiHost.Service, on: boolean): ()
          host.appearance = on
          host.sets += 1
        end,
        defaultAppearance = function(_self: uiHost.Service): boolean
          return host.appearance
        end,
      } :: any
    end,
  }).definition
  local componentsDefinition = plugin.provider<<{}, {}, uiComponents.Service>>({
    name = 'test/ui-components',
    capability = uiComponents.capability,
    requires = { uiHost.capability },
    build = function(_context: plugin.Context, _settings: {}): uiComponents.Service
      return {} :: any
    end,
  }).definition
  return hostDefinition, componentsDefinition
end

function fixture.boot(config: { [string]: unknown }?): Environment
  local native = testing.native()
  local host = { appearance = false, sets = 0 }
  local settings: { current: Settings? } = {}
  local env: Environment = {
    native = native,
    host = host,
    settings = settings,
  } :: any
  local observer = adapter.define {
    name = 'recovery-test-observer',
    requires = { composition.capability, surfaces.capability },
    init = function(context: adapter.Context): ()
      env.composition = context:require(composition.capability)
      env.surfaces = context:require(surfaces.capability)
      env.context = context
    end,
  }
  local configured = plugin.consumer({
    name = 'recovery-test-settings',
    schema = schema.object { value = schema.default(schema.number())(1) },
    init = function(_context: plugin.Context, current: Settings): ()
      settings.current = current
    end,
  }).definition
  local hostDefinition, componentsDefinition = standIns(host)
  local merged: { [string]: unknown } = table.clone(fixture.CONFIG)
  for key, value in config or {} do
    merged[key] = value
  end
  frameProvider.install {
    start = function(): () end,
    stop = function(): () end,
  }
  local entries: { any } = {}
  for _, id in
    {
      'frame',
      'theme',
      'surfaces',
      'drops',
      'focus',
      'bindings',
      'interaction',
      'laser',
      'keyboard',
      'desktop/pointing',
      'errors',
    }
  do
    entries[#entries + 1] = { id = id, definition = builtinEntries[id] }
  end
  entries[8] = {
    id = 'laser',
    definition = builtinEntries.laser,
    config = { aim = { enabled = false }, triggerLock = { enabled = false } },
  }
  for _, entry in
    {
      { id = 'ui-host', definition = hostDefinition },
      { id = 'ui-standard', definition = componentsDefinition },
      { id = 'settings', definition = configured },
      { id = 'diagnostics/recovery', definition = recovery.definition, config = merged },
      { id = 'observer', definition = observer },
    }
  do
    entries[#entries + 1] = entry
  end
  -- Saved settings in memory, so the recovery panel's saved settings action has something to set aside.
  local saved = {
    overrides = {} :: { [string]: { [string]: unknown } },
    write = function() end,
    report = function(message: string)
      error(message, 0)
    end,
    storable = function(): boolean
      return true
    end,
  }
  env.saved = saved
  env.running = management.start(entries, { protected = { 'diagnostics/recovery' }, saved = saved })
  env.controls = vrUi.attach(native)
  env.controls:pose('left', lovr.math.newMat4():translate(-5, 1.5, 0))
  env.controls:tracked('left', true)
  env.controls:step()

  function env.step(self: Environment, dt: number?): ()
    self.controls:step(dt)
  end
  function env.draw(self: Environment): ()
    self.controls:draw()
  end
  -- The recovery surface while it is offered.
  function env.panel(self: Environment): any?
    for _, surface in self.surfaces:all() do
      if (surface :: any).pickPriority == (merged.pickPriority or 1000) then
        return surface
      end
    end
    return nil
  end
  function env.click(self: Environment, id: layout.ActionId): ()
    local surface = assert(self:panel(), 'the recovery panel is offered')
    local limits = { recentErrors = 4, columns = 64 }
    local actions: { layout.Action } = {}
    for index, action in ORDER do
      actions[index] = { id = action, label = action, enabled = true }
    end
    local placed = layout.build({ reason = '', errors = {}, actions = actions }, limits)
    local rect = placed.actions[assert(table.find(ORDER, id))].rect
    self.controls:click({
      pose = surface.pose,
      width = surface.width,
      height = surface.height,
      logicalWidth = layout.WIDTH,
      logicalHeight = layout.height(limits),
      visible = true,
    }, rect.x + rect.width / 2, rect.y + rect.height / 2, 'right')
  end
  function env.entry(self: Environment, id: string): composition.Entry?
    for _, entry in self.composition:entries() do
      if entry.id == id then
        return entry
      end
    end
    return nil
  end
  function env.close(self: Environment): ()
    self.running.runtime:close()
    self.native.assertResourcesReleased()
  end
  return env
end

-- Runs a body against a booted composition and closes it even when the body fails.
function fixture.run(config: { [string]: unknown }?, body: (Environment) -> ()): ()
  local env = fixture.boot(config)
  local ok, problem = pcall(body, env)
  env:close()
  if not ok then
    error(problem, 0)
  end
end

return fixture

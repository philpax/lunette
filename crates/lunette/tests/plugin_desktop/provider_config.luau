-- Every built-in provider reads its configuration over its defaults, rejects
-- an option it does not take by name, and serves what it was configured with.
local plugin = require '@lunette-plugin'
local desktop = require '@lunette-desktop'
local panels = require '@lunette-contracts/panels'
local interaction = require '@lunette-contracts/interaction'
local laser = require '@lunette-contracts/laser'
local keyboard = require '@lunette-contracts/keyboard'
local rules = require '@lunette-contracts/rules'
local adoption = require '@lunette-contracts/adoption'
local layouts = require '@lunette-contracts/layouts'
local errors = require '@lunette-contracts/errors'
local laserModule = require '@lunette-plugins/laser'

local function raises(expected, run)
  local ok, message = pcall(run)
  assert(not ok, 'expected an error naming ' .. expected)
  assert(tostring(message):find(expected, 1, true), 'expected ' .. expected .. ', got ' .. tostring(message))
end

-- Each provider, started with an option it does not take, fails its own
-- activation with an error that names it and the option.
local rejections = {
  { id = 'frame', config = { bogus = 1 }, message = 'plugin frame: unknown option bogus; frame takes no options' },
  { id = 'surfaces', config = { bogus = 1 }, message = 'plugin surfaces: unknown option bogus' },
  { id = 'tags', config = { bogus = 1 }, message = 'plugin tags: unknown option bogus' },
  {
    id = 'panels',
    config = { style = { borderColour = { 1, 1, 1, 1 } } },
    message = 'plugin panels: unknown option style.borderColour; the options are borderColor,',
  },
  {
    id = 'interaction',
    config = { tuning = { reach = 'far' } },
    message = 'option tuning.reach is a number, not a string',
  },
  {
    id = 'interaction',
    config = { focusOnPress = 'yes' },
    message = 'plugin interaction: option focusOnPress is a boolean, not a string',
  },
  { id = 'interaction', config = { drive = 'remap' }, message = 'plugin interaction: option drive is a function' },
  {
    id = 'laser',
    config = { buttons = { { control = 'pinch', button = 'left' } } },
    message = 'plugin laser: option buttons[1].control is a controller button, not pinch',
  },
  {
    id = 'laser',
    config = { buttons = { { control = 'a', button = 'thumb' } } },
    message = 'plugin laser: option buttons[1].button is a pointer button, not thumb',
  },
  { id = 'panels', config = { chrome = 'on' }, message = 'plugin panels: option chrome is a boolean, not a string' },
  {
    id = 'panels',
    config = { shape = { raycst = function() end } },
    message = 'plugin panels: unknown option shape.raycst',
  },
  { id = 'drops', config = { bogus = 1 }, message = 'plugin drops: unknown option bogus' },
  { id = 'focus', config = { bogus = 1 }, message = 'plugin focus: unknown option bogus' },
  { id = 'bindings', config = { bogus = 1 }, message = 'plugin bindings: unknown option bogus' },
  { id = 'desktop/render', config = { bogus = 1 }, message = 'plugin desktop/render: unknown option bogus' },
  {
    id = 'desktop/monitors',
    config = { placement = { width = 0 } },
    message = 'plugin desktop/monitors: option placement.width is a positive number, not 0',
  },
  {
    id = 'desktop/monitors',
    config = { select = { 'DP-1', '' } },
    message = 'plugin desktop/monitors: option select[2] is a non-empty name',
  },
  { id = 'desktop/hint', config = { size = 0 }, message = 'plugin desktop/hint: option size is a positive number' },
  {
    id = 'desktop/decorations',
    config = { style = { barHeight = -1 } },
    message = 'plugin desktop/decorations: option style.barHeight is a positive number',
  },
  {
    id = 'desktop/pointing',
    config = { laser = { seat = {} } },
    message = 'plugin desktop/pointing: unknown option laser.seat',
  },
  {
    id = 'desktop/pointing',
    config = { laser = { style = 'red' } },
    message = 'plugin desktop/pointing: option laser.style is a table, not a string',
  },
  {
    id = 'desktop/bindings',
    config = { reload = { key = 'f5', modifiers = { 'hyper' } } },
    message = 'chord.modifiers[1] is one of control, alt, logo, shift, not hyper',
  },
  { id = 'desktop/pose-memory', config = { bogus = 1 }, message = 'plugin desktop/pose-memory: unknown option bogus' },
  { id = 'laser', config = { style = 'red' }, message = 'plugin laser: option style is a table, not a string' },
  { id = 'keyboard', config = { rows = 'qwerty' }, message = 'plugin keyboard: option rows is a table, not a string' },
  {
    id = 'keyboard',
    config = { layout = {} },
    message = 'plugin keyboard: unknown option layout; the options are drawKey, layers, locks, modifierKeys, onKey, rows, style',
  },
  {
    id = 'keyboard',
    config = { rows = { { { code = 30, widht = 2 } } } },
    message = 'plugin keyboard: option rows[1][1] has an unknown field widht',
  },
  {
    id = 'keyboard',
    config = { rows = { { { action = { kind = 'layer', layer = 'numpad' } } } } },
    message = 'plugin keyboard: option rows[1][1].action.layer names no layer: numpad',
  },
  {
    id = 'keyboard',
    config = { onKey = 'click' },
    message = 'plugin keyboard: option onKey is a function, not a string',
  },
  {
    id = 'keyboard',
    config = { locks = { 'shift', 'hyper' } },
    message = 'plugin keyboard: option locks[2] is a modifier name, not hyper',
  },
  { id = 'rules', config = { precedance = 1 }, message = 'plugin rules: unknown option precedance' },
  { id = 'adoption', config = { precedence = '300' }, message = 'plugin adoption: option precedence is a number' },
  {
    id = 'layout/arc',
    config = { tuning = { radious = 2 } },
    message = 'plugin layout/arc: unknown option tuning.radious',
  },
  {
    id = 'layout/arc',
    config = { tuning = { radius = 0 } },
    message = 'plugin layout/arc: option radius is a positive number, not 0',
  },
  { id = 'layouts', config = { bogus = 1 }, message = 'plugin layouts: unknown option bogus' },
  { id = 'errors', config = { colour = {} }, message = 'plugin errors: unknown option colour' },
  {
    id = 'errors',
    config = { history = 0 },
    message = 'plugin errors: option history is a whole number of at least 1, not 0',
  },
  {
    id = 'desktop/errors',
    config = { position = 'ahead' },
    message = 'plugin desktop/errors: option position is a table, not a string',
  },
  {
    id = 'desktop/errors',
    config = { position = { 0, 'up', -1 } },
    message = 'plugin desktop/errors: option position[2] is a number, not a string',
  },
  {
    id = 'desktop/errors',
    config = { background = { 1, 0, 0, 1, extra = true } },
    message = 'plugin desktop/errors: option background is a list of four numbers, and extra is not one of its positions',
  },
  { id = 'placement', config = { bogus = 1 }, message = 'plugin placement: unknown option bogus' },
  {
    id = 'placement',
    config = { panelOptions = 'curved' },
    message = 'plugin placement: option panelOptions is a function, not a string',
  },
  { id = 'desktop/workspace', config = { nmae = 'web' }, message = 'plugin desktop/workspace: unknown option nmae' },
  {
    id = 'desktop/rules',
    config = { rules = { match = {} } },
    message = 'rules: a rules list is a list, and match is not one of its positions',
  },
  {
    id = 'desktop/rules',
    config = { rules = { { matches = { appId = 'foot' } } } },
    message = 'rules: rule 1 has an unknown field matches; the fields are match and properties',
  },
  { id = 'desktop/persistence', config = { fiel = 'x' }, message = 'plugin desktop/persistence: unknown option fiel' },
  {
    id = 'desktop/persistence',
    config = { file = '' },
    message = 'plugin desktop/persistence: option file is a non-empty file name',
  },
  {
    id = 'desktop/persistence',
    config = { format = { read = 'lua' } },
    message = 'plugin desktop/persistence: option format.read is a function, not a string',
  },
  {
    id = 'desktop/arrange',
    config = { tags = { '' } },
    message = 'plugin desktop/arrange: option tags[1] is a non-empty tag name',
  },
  {
    id = 'desktop/adoption',
    config = { filter = 'everything' },
    message = 'plugin desktop/adoption: option filter is a function, not a string',
  },
  { id = 'desktop/arrange', config = { layuot = 'grid' }, message = 'plugin desktop/arrange: unknown option layuot' },
  -- A layout's own options are the layout's to validate, and its error fails
  -- the arranging consumer that passed them.
  {
    id = 'desktop/arrange',
    config = { options = { arc = { radious = 2 } } },
    message = 'plugin layout/arc: unknown option radious',
  },
  {
    id = 'desktop/arrange',
    config = { options = { radius = 2 } },
    message = 'plugin desktop/arrange: option options.radius is a table of options, not a number',
  },
  {
    id = 'desktop/adoption',
    config = { tags = { 'main', '' } },
    message = 'plugin desktop/adoption: option tags[2] is a non-empty tag name',
  },
  {
    id = 'desktop/demo-terminal',
    config = { programs = 'foot' },
    message = 'plugin desktop/demo-terminal: option programs is a table, not a string',
  },
  {
    id = 'pacing',
    config = { tuning = { exemptTypes = { movie = true } } },
    message = 'plugin pacing: unknown option tuning.exemptTypes.movie',
  },
  {
    id = 'pacing',
    config = { tuning = { background = 0 } },
    message = 'plugin pacing: option tuning.background is a rate in hertz above zero, not 0',
  },
  {
    id = 'pacing',
    config = { tuning = { history = 0.5 } },
    message = 'plugin pacing: option tuning.history is a whole number of at least 1, not 0.5',
  },
  {
    id = 'pacing',
    config = { tuning = { busy = 2 } },
    message = 'plugin pacing: option tuning.busy is a fraction above 0 and at most 1, not 2',
  },
  { id = 'pacing', config = { choose = 30 }, message = 'plugin pacing: option choose is a function, not a number' },
  { id = 'scale', config = { steps = { 1, 2 } }, message = 'plugin scale: unknown option steps' },
  {
    id = 'scale',
    config = { tuning = { lower = 1 } },
    message = 'plugin scale: option tuning.lower is a fraction of at least 0 and below 1, not 1',
  },
  {
    id = 'scale',
    config = { tuning = { reference = -1 } },
    message = 'plugin scale: option tuning.reference is a distance in metres above zero, not -1',
  },
  { id = 'scale', config = { ideal = 2 }, message = 'plugin scale: option ideal is a function, not a number' },
  {
    id = 'desktop/pacing',
    config = { pauseMonitors = 'yes' },
    message = 'plugin desktop/pacing: option pauseMonitors is a boolean, not a string',
  },
  { id = 'desktop/scale', config = { bogus = 1 }, message = 'plugin desktop/scale: unknown option bogus' },
}
for _, case in ipairs(rejections) do
  local running = desktop.start(desktop.compose { patches = { { id = case.id, config = case.config } } })
  local instance = running.instances[case.id]
  assert(instance:state() == 'failed', case.id .. ' is ' .. instance:state())
  local diagnostic = tostring(instance:diagnostic())
  assert(diagnostic:find(case.message, 1, true), case.id .. ': ' .. diagnostic)
  running.runtime:close()
end

-- A configuration that is not a table is the provider's to reject too, when it
-- is used outside a composition, which rejects one first.
local direct = plugin.runtime()
local loud = direct:use(require('@lunette-plugins/errors').definition, 'loud' :: any)
loud:enable()
assert(
  tostring(loud:diagnostic()):find('plugin errors: the configuration is a table of options, not a string', 1, true)
)
direct:close()

-- A configured desktop serves the configured values; a record merges over the
-- defaults, so what a configuration leaves out keeps its default.
local services, owner = {}, nil
local probe = plugin.define {
  name = 'probe',
  requires = {
    panels = panels.capability,
    interaction = interaction.capability,
    laser = laser.capability,
    keyboard = keyboard.capability,
    rules = rules.capability,
    adoption = adoption.capability,
    layouts = layouts.capability,
    errors = errors.capability,
  },
  init = function(context)
    owner = context
    services.panels = context:require(panels.capability)
    services.interaction = context:require(interaction.capability)
    services.laser = context:require(laser.capability)
    services.keyboard = context:require(keyboard.capability)
    services.rules = context:require(rules.capability)
    services.adoption = context:require(adoption.capability)
    services.layouts = context:require(layouts.capability)
    services.errors = context:require(errors.capability)
  end,
}
-- LÖVR's callbacks reach the frame provider of the desktop started next, so
-- the error panel draws.
require('@lunette-plugins/frame').install { start = function() end, stop = function() end }
local running = desktop.start(desktop.compose {
  patches = {
    { id = 'panels', config = { height = 1.2, style = { borderThickness = 0.02 } } },
    { id = 'interaction', config = { tuning = { reach = 0.5 } } },
    { id = 'laser', config = { style = { length = 2.5 } } },
    { id = 'desktop/pointing', config = { laser = { style = { color = { 0.9, 0.9, 0.9, 1 } } } } },
    {
      id = 'keyboard',
      config = { rows = { { { code = 30 }, { code = 31, width = 2 } } }, style = { keyUnit = 0.056 } },
    },
    { id = 'rules', config = { precedence = 150 } },
    { id = 'adoption', config = { precedence = 350 } },
    { id = 'layout/arc', config = { tuning = { radius = 3 } } },
    { id = 'errors', config = { history = 2 } },
    { id = 'desktop/errors', config = { columns = 10, background = { 0, 0, 1, 1 } } },
    { insert = { id = 'probe', definition = probe } },
  },
})
for id, instance in pairs(running.instances) do
  assert(instance:state() == 'active', id .. ': ' .. tostring(instance:diagnostic()))
end

assert(services.panels.STYLE.borderThickness == 0.02 and services.panels.STYLE.borderDepth == 0.001)
assert(table.isfrozen(services.panels.STYLE), 'a configured style is frozen')
local window = newWindow(90)
local panel = services.panels:fromWindow(owner, window, {})
assert(panel.height == 1.2, 'a panel given no size takes the configured height')
assert(panel.priority == 10 and panel.chrome == false, 'what is not configured keeps its default')

assert(services.interaction.TUNING.reach == 0.5 and services.interaction.TUNING.scrollScale == 900)
local near = {
  dead = false,
  raycast = function()
    return 0.5, 0.5, 1
  end,
}
local probePointer = services.interaction:newPointer(owner)
probePointer:update(
  { origin = vector.pack(0, 0, 0), direction = vector.pack(0, 0, -1), buttons = {}, grip = false },
  { near }
)
assert(probePointer.hovered == nil, 'reach limits picking')
probePointer:destroy()

assert(services.laser.STYLE.length == 2.5 and services.laser.STYLE.cursorRadius == 0.006)
local left = assert(services.laser:forHand 'left')
assert(left.style.color[1] == 0.9 and left.style.length == 2.5, 'desktop/pointing attaches with its laser options')

local typed = services.keyboard:new(owner, {})
assert(typed.width == 3 * 0.056 and typed.height == 0.056, 'the configured rows and style set the keyboard size')
assert(#typed:keys() == 2 and typed:keys()[2].width == 2 * 0.056, 'a new keyboard takes the configured rows')
typed:destroy()
local own = services.keyboard:new(owner, { style = { keyUnit = 0.01 } })
assert(own.width == 3 * 0.01, "a keyboard's own style merges over the configured one")
own:destroy()
raises('plugin keyboard: unknown option style.keyUnits', function()
  services.keyboard:new(owner, { style = { keyUnits = 0.01 } })
end)

assert(services.rules.DEFAULT_PRECEDENCE == 150)
services.rules:setRules(owner, { name = 'probe', rules = {} })
assert(services.adoption.PRECEDENCE == 350)
local precedences = {}
for _, source in ipairs(services.rules:sources()) do
  precedences[source.name] = source.precedence
end
assert(precedences.probe == 150, 'a rule set without a precedence takes the configured one')
assert(precedences['lunette.adoption'] == 350, 'adoption installs its source at the configured precedence')

assert(services.layouts:get('arc').continuous == false, 'the arc registers as a layout')
local arced = { width = 1, dead = false }
function arced:setPose(pose)
  self.pose = pose
end
services.layouts:apply { name = 'arc', panels = { arced } }
local _, y, z = arced.pose:getPosition()
assert(y == 1.5 and z == -3, 'the arc is laid out at the configured radius and default centre: ' .. tostring(z))
services.layouts:apply { name = 'arc', panels = { arced }, options = { radius = 2 } }
_, _, z = arced.pose:getPosition()
assert(z == -2, "a call's options merge over the configured tuning")

for index = 1, 3 do
  emit('onError', { message = 'report ' .. index, traceback = '' })
end
local recent = services.errors:recent()
assert(#recent == 2 and recent[2].message == 'report 3', 'the stream keeps the configured history')
emit('onError', { message = 'a report longer than ten columns', traceback = '' })
events.draw = {}
lovr.draw(events.pass)
-- The panel draws a fixed heading and the report wrapped below it, among the
-- other text of the scene.
local report = 'a report longer than ten columns'
local wrapped = {}
for _, call in ipairs(events.draw) do
  local text = tostring(call[2])
  if call[1] == 'text' and text ~= '' and report:find(text, 1, true) then
    wrapped[#wrapped + 1] = text
  end
end
assert(#wrapped >= 3 and table.concat(wrapped, ' ') == report, 'the error panel draws the wrapped report')
for _, line in ipairs(wrapped) do
  assert(#line <= 10, 'the report wraps at the configured columns: ' .. line)
end

panel:destroy(owner)
running.runtime:close()

-- define makes another definition whose options are the new defaults, and a
-- configuration still merges over them.
local long = laserModule.define { name = 'long-laser', style = { length = 3 } }
assert(long.name == 'long-laser' and laserModule.definition.name == 'laser')
local defined = desktop.start(desktop.compose {
  patches = {
    { id = 'laser', definition = long, config = { style = { color = { 1, 0, 0, 1 } } } },
    { insert = { id = 'probe', definition = probe } },
  },
})
assert(defined.instances.laser:state() == 'active', tostring(defined.instances.laser:diagnostic()))
assert(services.laser.STYLE.length == 3 and services.laser.STYLE.color[1] == 1 and services.laser.STYLE.color[2] == 0)
defined.runtime:close()
assert(laserModule.define({}).name == 'laser', 'define without a name keeps the default name')

-- define and build reject what a configuration rejects, at the call.
local built = {}
local builder = plugin.define {
  name = 'builder',
  requires = laserModule.requires,
  init = function(context)
    built.ok, built.message = pcall(laserModule.build, context, { style = { colour = {} } })
    built.service = laserModule.build(context)
  end,
}
local building = desktop.start(desktop.compose { patches = { { insert = { id = 'builder', definition = builder } } } })
assert(building.instances.builder:state() == 'active', tostring(building.instances.builder:diagnostic()))
assert(not built.ok and tostring(built.message):find('plugin laser: unknown option style.colour', 1, true))
assert(built.service.STYLE.length == 1.5, 'build without a configuration takes the defaults')
building.runtime:close()
raises('plugin laser: unknown option bogus', function()
  laserModule.define { bogus = 1 }
end)
raises('plugin short-laser: option style.length is a number, not a string', function()
  laserModule.define { name = 'short-laser', style = { length = 'short' } }
end)
raises('define names a definition with a non-empty string, not 5', function()
  laserModule.define { name = 5 }
end)

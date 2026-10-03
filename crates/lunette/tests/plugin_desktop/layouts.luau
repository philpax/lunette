-- The layouts broker, the arc's spacing, placement's announcements, and the
-- arranging consumer waiting for its layout, in the shipped composition.
local plugin = require '@lunette-plugin'
local layoutsContract = require '@lunette-contracts/layouts'
local placementContract = require '@lunette-contracts/placement'
local geometry = require '@lunette-plugins/layout/arc/geometry'

local function raises(expected, run)
  local ok, message = pcall(run)
  assert(not ok, 'expected an error naming ' .. expected)
  assert(tostring(message):find(expected, 1, true), 'expected ' .. expected .. ', got ' .. tostring(message))
end

local function probe(desktop, name)
  local found = {}
  local instance = desktop.runtime:use(
    plugin.define {
      name = name,
      requires = { layouts = layoutsContract.capability, placement = placementContract.capability },
      init = function(context)
        found.owner = context
        found.layouts = context:require(layoutsContract.capability)
        found.placement = context:require(placementContract.capability)
      end,
    },
    {}
  )
  instance:enable()
  found.instance = instance
  return found
end

local function moving(width)
  local panel = { dead = false, width = width }
  function panel:setPose(pose)
    self.pose = pose
  end
  return panel
end

-- The arc does not overlap panels that fit its span, and shrinks the separations to fill the span exactly
-- when they do not. The widths are a fixed pseudo-random sequence.
local tuning = { radius = 1.6, step = 0.55, span = math.pi * 1.2, gap = 0.05, center = { 0, 1.5, 0 } }
assert(#geometry.angles({}, tuning) == 0)
assert(#geometry.angles({ 3 }, tuning) == 1 and geometry.angles({ 3 }, tuning)[1] == 0, 'one panel is centred')
local seed = 7
local function nextWidth()
  seed = (seed * 1103515245 + 12345) % 2147483648
  return 0.2 + (seed % 1000) / 1000 * 2.3
end
for count = 2, 9 do
  local widths = {}
  for index = 1, count do
    widths[index] = nextWidth()
  end
  local angles = geometry.angles(widths, tuning)
  local extent = angles[count] - angles[1]
  assert(math.abs(angles[1] + angles[count]) < 1e-12, 'the arc is centred')
  if extent < tuning.span - 1e-12 then
    for index = 1, count - 1 do
      local needed = math.atan(widths[index] / 2 / tuning.radius)
        + math.atan(widths[index + 1] / 2 / tuning.radius)
        + tuning.gap / tuning.radius
      local apart = angles[index + 1] - angles[index]
      assert(apart >= needed - 1e-12 and apart >= tuning.step - 1e-12, 'panels ' .. index .. ' and ' .. index + 1)
    end
  else
    assert(math.abs(extent - tuning.span) < 1e-12, 'an arc that does not fit fills the span')
  end
end
-- Narrow panels keep the minimum step.
local narrow = geometry.angles({ 0.1, 0.1, 0.1 }, tuning)
assert(math.abs(narrow[2] - narrow[1] - tuning.step) < 1e-12)

local desktop = require 'fixture/graph'()
local first = probe(desktop, 'layouts-probe-1')
local layouts, owner = first.layouts, first.owner

-- Registration validates its fields, and a name is one registration.
assert(table.concat(layouts:names(), ',') == 'arc')
raises('layouts register: unknown field fn; the fields are name, apply, and continuous', function()
  layouts:register(owner, { name = 'x', fn = function() end })
end)
raises('layouts register: name is a non-empty string', function()
  layouts:register(owner, { name = '', apply = function() end })
end)
raises('layouts register: continuous is a boolean', function()
  layouts:register(owner, { name = 'x', apply = function() end, continuous = 1 })
end)
raises('layouts register: arc is already registered', function()
  layouts:register(owner, { name = 'arc', apply = function() end })
end)

-- A change listener hears registrations begin and end, and one that raises does not stop the next. The
-- listeners have an owner of their own, because an owner has no authority while its own effect is disposed.
local listening = probe(desktop, 'layouts-listener')
local heard = 0
listening.layouts:onChanged(listening.owner, {
  run = function()
    error 'a raising change listener'
  end,
})
listening.layouts:onChanged(listening.owner, {
  run = function()
    heard += 1
  end,
})
events.reported = {}
local seen
local stack = layouts:register(owner, {
  name = 'stack',
  apply = function(panels, options)
    seen = { count = #panels, options = options }
  end,
})
assert(heard == 1 and #events.reported == 1, 'registration is heard')
assert(events.reported[1].message:find('layouts: a change listener', 1, true))
assert(table.concat(layouts:names(), ',') == 'arc,stack')
local entry = layouts:get 'stack'
assert(entry.name == 'stack' and entry.continuous == false and table.isfrozen(entry))
assert(layouts:get 'missing' == nil)

-- apply passes the live panels and the options, and names what is
-- registered when the name is not.
local dead = moving(1)
dead.dead = true
layouts:apply { name = 'stack', panels = { moving(1), dead, moving(1) }, options = { depth = 2 } }
assert(seen.count == 2 and seen.options.depth == 2, 'a layout receives the live panels and the options')
raises('layouts apply: no layout is registered as grid; the layouts are arc, stack', function()
  layouts:apply { name = 'grid', panels = {} }
end)
raises('layouts apply: unknown field layout', function()
  layouts:apply { layout = 'arc', panels = {} }
end)
raises('plugin layout/arc: unknown option radious', function()
  layouts:apply { name = 'arc', panels = { moving(1) }, options = { radious = 1 } }
end)
stack:dispose()
assert(heard == 2 and layouts:get 'stack' == nil, 'disposal ends the registration and is heard')

-- A registration ends with its owner, and the name is free again.
local second = probe(desktop, 'layouts-probe-2')
second.layouts:register(second.owner, { name = 'owned', apply = function() end, continuous = true })
assert(layouts:get('owned').continuous == true)
second.instance:disable()
assert(layouts:get 'owned' == nil and heard == 4)

-- Placement announces each placement with the properties it was placed with,
-- whoever made it, and lists the live placements in placement order. A
-- listener that raises is reported and does not undo the placement.
local announced = {}
first.placement:onPlaced(owner, {
  run = function(placed)
    announced[#announced + 1] = placed
  end,
})
first.placement:onPlaced(owner, {
  run = function()
    error 'a raising placement listener'
  end,
})
raises('placement onPlaced: unknown field callback', function()
  first.placement:onPlaced(owner, { callback = function() end })
end)
events.reported = {}
local terminal, browser = newWindow(40), newWindow(41, 'firefox')
events.windows = { terminal, browser }
emit('onWindowOpened', { window = terminal })
emit('onWindowOpened', { window = browser })
assert(#announced == 2 and #events.reported == 2)
assert(announced[1].properties.pose == nil and announced[2].properties.pose ~= nil, 'the rules placed only firefox')
local placed = first.placement:placed()
assert(#placed == 2 and placed[1].panel == announced[1].panel and placed[2].panel == announced[2].panel)
assert(not placed[1].panel.dead, 'a raising listener does not undo the placement')
terminal.dead = true
lovr.update(0.016)
assert(#first.placement:placed() == 1, 'a placement ends with its panel')
assert(lovr.quit() == false)

-- An arranging consumer whose layout is not registered reports it on the
-- first frame, once, and arranges as soon as the layout registers.
events.windows = { newWindow(50) }
events.saved = nil
events.logs = {}
local waiting = require 'fixture/graph' { patches = { { id = 'desktop/arrange', config = { layout = 'later' } } } }
lovr.update(0.016)
lovr.update(0.016)
local warnings = 0
for _, log in ipairs(events.logs) do
  if log[1]:find('desktop/arrange: later is not a registered layout; the registered layouts are arc', 1, true) then
    warnings += 1
  end
end
assert(warnings == 1, 'the missing layout is reported once')
local late = probe(waiting, 'layouts-probe-3')
local arranged = 0
late.layouts:register(late.owner, {
  name = 'later',
  apply = function(panels)
    arranged = #panels
  end,
})
assert(arranged == 1, 'the consumer arranges when its layout registers')
assert(lovr.quit() == false)

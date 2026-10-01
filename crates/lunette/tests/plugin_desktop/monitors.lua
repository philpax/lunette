-- Monitor mirrors laid side by side, chosen by name, and tagged.
local function x(panel)
  local value = panel.pose:getPosition()
  return value
end
local function near(first, second)
  return math.abs(first - second) < 1e-9
end
local function plug(name)
  local monitor = newMonitor(name)
  events.monitors[monitor.id] = monitor
  return monitor
end

-- The monitors present at activation are placed in name order, from the
-- centre outward, the right before the left.
local b, a = plug 'B', plug 'A'
local desktop = require 'fixture/graph'()
local service = desktop.panels
local first, second = assert(service:forSource(a)), assert(service:forSource(b))
assert(near(x(first), 0) and near(x(second), 2.1), 'two mirrors side by side: ' .. x(first) .. ', ' .. x(second))
assert(first.width == 2 and second.width == 2)
local c = plug 'C'
emit('onMonitorAdded', { id = c.id, monitor = c })
local third = assert(service:forSource(c))
assert(near(x(third), -2.1), 'a third mirror goes to the left')

-- A mirror that goes away leaves its place to the next.
b.dead = true
events.monitors[b.id] = nil
lovr.update(0.016)
assert(second.dead)
local d = plug 'D'
emit('onMonitorAdded', { id = d.id, monitor = d })
assert(near(x(assert(service:forSource(d))), 2.1), 'a new mirror takes the free place')
assert(lovr.quit() == false)
desktop.runtime:close()
events.monitors = {}

-- `select` mirrors only the named monitors; `placement` sets the row; `tags`
-- are joined by every mirror, through a child that a tags outage takes away
-- without the mirrors.
local e, f = plug 'E', plug 'F'
desktop = require 'fixture/graph' {
  patches = {
    {
      id = 'desktop/monitors',
      config = {
        select = { 'F', 'G' },
        placement = { center = { 1, 2, -3 }, width = 1, gap = 0.5 },
        tags = { 'main', 'missing' },
      },
    },
  },
}
service = desktop.panels
assert(service:forSource(e) == nil, 'an unselected monitor is not mirrored')
local mirrored = assert(service:forSource(f))
local px, py, pz = mirrored.pose:getPosition()
assert(px == 1 and py == 2 and pz == -3 and mirrored.width == 1, 'the placement places the first mirror')
local g = plug 'G'
emit('onMonitorAdded', { id = g.id, monitor = g })
assert(near(x(assert(service:forSource(g))), 2.5), 'the next is one width and gap to the right')

local tags
local plugin = require '@lunette-plugin'
local tagsContract = require '@lunette-contracts/tags'
desktop.runtime
  :use(
    plugin.define {
      name = 'monitors-probe',
      requires = { tags = tagsContract.capability },
      init = function(context)
        tags = context:require(tagsContract.capability)
      end,
    },
    {}
  )
  :enable()
local main = assert(tags:find 'main')
assert(main:has(mirrored) and main:has(service:forSource(g)), 'every mirror joins the configured tag')
local warned = false
for _, entry in ipairs(events.logs) do
  if tostring(entry[1]):find('missing is not a tag', 1, true) then
    warned = true
  end
end
assert(warned, 'a tag that does not exist is reported')
desktop.providers.tags:disable()
assert(desktop.consumers.monitors:state() == 'active', 'a tags outage keeps the mirrors')
assert(not mirrored.dead)
desktop.providers.tags:enable()
main = assert(tags:find 'main')
assert(main:has(mirrored), 'recovery tags the mirrors again')
assert(lovr.quit() == false)

local testing = require '@testing'
local interaction = require '@lunette-contracts/interaction'
local expect = testing.expect

return function(provider)
  testing.native()
  local lunette = require '@lunette'
  local seat = lunette.newSeat 'protocol-fixture'
  lunette.defaultSeat = function()
    return seat
  end
  local entry = if provider then { id = 'interaction', definition = provider } else 'interaction'
  local session = testing.start { 'drops', 'focus', entry }
  local observed = session:observe(interaction.capability)
  local f = { session = session, service = observed.service, owner = observed.context, events = {}, legacy = 0 }
  function f:pointer()
    return self.service:newPointer(self.owner)
  end
  function f:surface(name)
    local target = { dead = false, grabbable = false, name = name }
    function target:raycast(origin)
      if math.abs(origin.x) <= 0.5 and math.abs(origin.y) <= 0.5 then
        return origin.x + 0.5, 0.5 - origin.y, 1
      end
      return nil, nil, nil
    end
    function target:project(origin)
      return origin.x + 0.5, 0.5 - origin.y, 1
    end
    function target:onPointer(event)
      expect.truthy(table.isfrozen(event), 'pointer metadata is immutable')
      f.events[#f.events + 1] = { surface = self, event = event }
    end
    function target:onPress()
      f.legacy += 1
    end
    function target:onRelease()
      f.legacy += 1
    end
    function target:onHover()
      f.legacy += 1
    end
    function target:onLeave()
      f.legacy += 1
    end
    return target
  end
  function f:update(pointer, surfaces, fields)
    fields = fields or {}
    pointer:update({
      origin = vector.pack(fields.x or 0, fields.y or 0, 0),
      direction = vector.pack(0, 0, -1),
      pose = lovr.math.newMat4():translate(fields.x or 0, fields.y or 0, 0),
      buttons = fields.buttons or {},
      grip = fields.grip or false,
      scrollX = fields.scrollX,
      scrollY = fields.scrollY,
      dt = fields.dt or 1,
    }, surfaces)
  end
  function f:matching(kind, pointer, target, button)
    local result = {}
    for _, entry in ipairs(self.events) do
      local event = entry.event
      if
        event.kind == kind
        and (not pointer or event.pointer == pointer)
        and (not target or entry.surface == target)
        and (not button or event.button == button)
      then
        result[#result + 1] = event
      end
    end
    return result
  end
  function f:close()
    self.session:close()
  end
  return f
end

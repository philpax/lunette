local testing = require '@testing'
local interaction = require '@lunette-contracts/interaction'

type Context = testing.Context
type Buttons = { [string]: boolean }
export type Fields = {
  read x: number?,
  read y: number?,
  read buttons: Buttons?,
  read grip: boolean?,
  read scrollX: number?,
  read scrollY: number?,
  read dt: number?,
}
export type Surface = {
  dead: boolean,
  grabbable: boolean,
  name: string,
  pose: Mat4?,
  width: number?,
  height: number?,
  raycast: (Surface, vector) -> (number?, number?, number?),
  project: (Surface, vector) -> (number, number, number),
  onPointer: (Surface, interaction.PointerEvent) -> (),
  setPose: ((Surface, Mat4) -> ())?,
  sink: ((Surface) -> { read dead: boolean, read domain: string })?,
}
export type Event = { surface: interaction.Surface, event: interaction.PointerEvent }
export type Fixture = {
  session: testing.Session,
  service: interaction.Service,
  owner: Context,
  events: { Event },
  pointer: (Fixture) -> interaction.Pointer,
  surface: (Fixture, string) -> Surface,
  update: (Fixture, interaction.Pointer, { interaction.Surface }, Fields?) -> (),
  matching: (Fixture, string, interaction.Pointer?, interaction.Surface?, string?) -> { interaction.PointerEvent },
  close: (Fixture) -> (),
}
type Definition = {
  read name: string,
  read requires: { { read witness: (never) -> unknown } },
  read provides: { { read witness: (never) -> unknown } },
  read init: (never, never, never) -> (),
}

return function(provider: Definition?): Fixture
  testing.native()
  local lunette = require '@lunette'
  local seat = lunette.newSeat { name = 'protocol-fixture' }
  lunette.defaultSeat = function(): typeof(seat)
    return seat
  end
  local entry = if provider then { id = 'interaction', definition = provider } else 'interaction'
  local session = testing.start { 'drops', 'focus', entry }
  local observed = session:observe(interaction.capability)
  local f: Fixture = { session = session, service = observed.service, owner = observed.context, events = {} }
  function f:pointer(): interaction.Pointer
    return self.service:newPointer(self.owner)
  end
  function f:surface(name: string): Surface
    local target: Surface = { dead = false, grabbable = false, name = name }
    function target:raycast(origin: vector): (number?, number?, number?)
      if math.abs(origin.x) <= 0.5 and math.abs(origin.y) <= 0.5 then
        return origin.x + 0.5, 0.5 - origin.y, 1
      end
      return nil, nil, nil
    end
    function target:project(origin: vector): (number, number, number)
      return origin.x + 0.5, 0.5 - origin.y, 1
    end
    function target:onPointer(event: interaction.PointerEvent)
      f.events[#f.events + 1] = { surface = self, event = event }
    end
    return target
  end
  function f:update(pointer: interaction.Pointer, surfaces: { interaction.Surface }, fields: Fields?)
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
  function f:matching(
    kind: string,
    pointer: interaction.Pointer?,
    target: interaction.Surface?,
    button: string?
  ): { interaction.PointerEvent }
    local result: { interaction.PointerEvent } = {}
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

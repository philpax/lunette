-- Drives real desktop pointing through the fake XR boundary and discovers current public UI geometry.

local session = require '@testing/session'
local native = require '@testing/native'
local keyboard = require '@lunette-contracts/keyboard'
type Inspection = typeof(require '@lunette-contracts/inspection')
type Plugin = typeof(require '@lunette-plugin')

local vrUi = {}

export type Hand = 'left' | 'right'
export type Bounds = { x: number, y: number, width: number, height: number }
export type Item = { id: string, label: string, enabled: boolean, selected: boolean?, bounds: Bounds? }
export type Control = {
  id: string,
  owner: Plugin.Owner,
  kind: string,
  label: string?,
  enabled: boolean,
  bounds: Bounds?,
  items: { Item },
}
export type Geometry = {
  read pose: Mat4 | { number },
  read width: number,
  read height: number,
  read logicalWidth: number,
  read logicalHeight: number,
  read visible: boolean,
}
export type Description = Geometry & { name: string, revision: number, controls: { Control } }
-- Inspection services keep their own receivers; the fixture only reads their snapshots.
export type Inspectable<S> = { read inspect: (S) -> Inspection.Snapshot }
export type Fixture = {
  native: native.Fake,
  session: session.Session?,
  keyboardObserver: session.Observed<keyboard.Service>?,
  tracked: (Fixture, Hand, boolean) -> (),
  button: (Fixture, Hand, string, boolean) -> (),
  axis: (Fixture, Hand, number, number) -> (),
  pose: (Fixture, Hand, Mat4) -> (),
  aim: (Fixture, Geometry, number, number, Hand?) -> (),
  step: (Fixture, number?) -> (),
  draw: (Fixture) -> boolean,
  click: (Fixture, Geometry, number, number, Hand?) -> (),
  discover: <S>(Fixture, S & Inspectable<S>, string, string, string?) -> (Description, Control | Item),
  clickControl: <S>(Fixture, S & Inspectable<S>, string, string, Hand?, string?) -> (),
  nativeCalls: (Fixture, string) -> { native.InputCall },
  keyboardCount: (Fixture) -> number,
  close: (Fixture) -> (),
}
local Fixture = {}
Fixture.__index = Fixture

local function controller(fixture: Fixture, hand: Hand): native.Controller
  assert(hand == 'left' or hand == 'right', 'vr-ui: a hand is left or right')
  return fixture.native.events.controllers[hand]
end

-- Attaches controller input to a configuration already driven through LÖVR callbacks.
function vrUi.attach(fake: native.Fake): Fixture
  for _, hand in ipairs { 'left', 'right' } do
    fake.events.controllers[hand] = {
      tracked = false,
      origin = vector.pack(0, 1.5, 0),
      direction = vector.pack(0, 0, -1),
      pose = lovr.math.newMat4():translate(0, 1.5, 0),
      buttons = {},
      axisX = 0,
      axisY = 0,
    }
  end
  return setmetatable({ native = fake }, Fixture)
end

-- Attaches both hands tracked and aiming ahead, with the left hand held aside so only the right beam can hit.
function vrUi.hands(fake: native.Fake): Fixture
  local fixture = vrUi.attach(fake)
  fixture:pose('left', lovr.math.newMat4():translate(-5, 1.5, 0))
  fixture:tracked('left', true)
  fixture:tracked('right', true)
  return fixture
end

function vrUi.boot(entries: { session.Entry }?, options: session.Options?): Fixture
  local fake = options and options.native or native.new()
  local fixture = vrUi.attach(fake)
  local running = session.boot(entries or {
    'frame',
    'surfaces',
    'drops',
    'focus',
    'interaction',
    'laser',
    'keyboard',
    'desktop/pointing',
  }, { native = fake })
  fixture.session = running
  return fixture
end

function Fixture.tracked(self: Fixture, hand: Hand, value: boolean)
  controller(self, hand).tracked = value
end

function Fixture.button(self: Fixture, hand: Hand, button: string, pressed: boolean)
  controller(self, hand).buttons[button] = pressed
end

function Fixture.axis(self: Fixture, hand: Hand, x: number, y: number)
  local state = controller(self, hand)
  state.axisX, state.axisY = x, y
end

function Fixture.pose(self: Fixture, hand: Hand, pose: Mat4)
  local state = controller(self, hand)
  state.pose:set(pose)
  state.origin = vector.pack(pose:getPosition())
  state.direction = vector.pack(pose:mul(0, 0, -1, 0)):normalize()
end

function Fixture.aim(self: Fixture, description: Geometry, x: number, y: number, hand: Hand?)
  local state = controller(self, hand or 'right')
  assert(description.visible, 'vr-ui: the panel is hidden')
  assert(description.logicalWidth > 0 and description.logicalHeight > 0, 'vr-ui: logical size is positive')
  local localX = (x / description.logicalWidth - 0.5) * description.width
  local localY = (0.5 - y / description.logicalHeight) * description.height
  local pose = if type(description.pose) == 'table'
    then lovr.math.newMat4(table.unpack(description.pose))
    else lovr.math.newMat4(description.pose)
  pose:translate(localX, localY, 1)
  self:pose(hand or 'right', pose)
  state.tracked = true
end

function Fixture.step(self: Fixture, dt: number?)
  self.native.events.dt = dt or 0.016
  self.native.events.time += self.native.events.dt
  lovr.update(self.native.events.dt)
end

function Fixture.draw(self: Fixture): boolean
  return lovr.draw(self.native.events.pass)
end

function Fixture.click(self: Fixture, description: Geometry, x: number, y: number, hand: Hand?)
  hand = hand or 'right'
  self:button(hand, 'trigger', false)
  self:aim(description, x, y, hand)
  self:step()
  self:button(hand, 'trigger', true)
  self:step()
  self:button(hand, 'trigger', false)
  self:step()
end

local function bounds(details: Inspection.Details): Bounds?
  if details.width == nil then
    return nil
  end
  return { x = details.x, y = details.y, width = details.width, height = details.height }
end

-- Rebuilds a panel's description from the ui service's inspection, or nil when no live panel has the name.
function vrUi.describe<S>(service: S & Inspectable<S>, name: string): Description?
  local panel: Inspection.Registration? = nil
  local controls: { Control } = {}
  local byId: { [string]: Control } = {}
  for _, registration in ipairs(service:inspect().registrations) do
    local details = registration.details
    if registration.kind == 'panel' and registration.name == name then
      panel = registration
    elseif registration.kind == 'control' and details.panel == name then
      local control = {
        id = registration.name,
        owner = registration.owner,
        kind = details.kind,
        label = details.label,
        enabled = details.enabled,
        bounds = bounds(details),
        items = {},
      }
      controls[#controls + 1] = control
      byId[registration.name] = control
    elseif registration.kind == 'item' and details.panel == name then
      local items = byId[details.control].items
      items[#items + 1] = {
        id = registration.name,
        label = details.label,
        enabled = details.enabled,
        selected = details.selected,
        bounds = bounds(details),
      }
    end
  end
  if panel == nil then
    return nil
  end
  local details = panel.details
  local pose = lovr.math.newMat4():translate(details.x, details.y, details.z)
  pose:rotate(details.angle, details.ax, details.ay, details.az)
  return {
    name = name,
    revision = details.revision,
    pose = { pose:unpack(true) },
    width = details.width,
    height = details.height,
    logicalWidth = details.logicalWidth,
    logicalHeight = details.logicalHeight,
    visible = details.visible,
    controls = controls,
  }
end

function Fixture.discover<S>(
  self: Fixture,
  service: S & Inspectable<S>,
  name: string,
  id: string,
  itemId: string?
): (Description, Control | Item)
  local description = vrUi.describe(service, name)
  local foundControl: Control?
  local foundItem: Item?
  if description and description.visible then
    for _, control in ipairs(description.controls) do
      if control.id == id and control.enabled then
        assert(foundControl == nil, 'vr-ui: ambiguous control ' .. name .. '/' .. id)
        foundControl = control
        if itemId then
          for _, item in ipairs(control.items) do
            if item.id == itemId and item.enabled then
              foundItem = item
            end
          end
        end
      end
    end
  end
  if foundControl and (itemId == nil or foundItem ~= nil) then
    return description, foundItem or foundControl
  end
  error('vr-ui: no visible enabled control ' .. name .. '/' .. id .. (if itemId then '/' .. itemId else ''), 2)
end

-- Aims again after each step because a panel can follow the hand that moved.
function Fixture.clickControl<S>(
  self: Fixture,
  service: S & Inspectable<S>,
  name: string,
  id: string,
  hand: Hand?,
  itemId: string?
)
  hand = hand or 'right'
  local function aimCurrent()
    local description, control = self:discover(service, name, id, itemId)
    local bounds = control.bounds
    assert(bounds and bounds.width > 0 and bounds.height > 0, 'vr-ui: the control has no visible hit bounds')
    self:aim(description, bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, hand)
  end
  self:button(hand, 'trigger', false)
  self:step()
  aimCurrent()
  self:step()
  aimCurrent()
  self:button(hand, 'trigger', true)
  self:step()
  self:button(hand, 'trigger', false)
  self:step()
end

local function matching<E>(
  events: { E & { read kind: string?, read [number]: unknown } },
  kind: string
): { E & { read kind: string?, read [number]: unknown } }
  local result: { E & { read kind: string?, read [number]: unknown } } = {}
  for _, event in ipairs(events) do
    if event.kind == kind or event[1] == kind then
      result[#result + 1] = event
    end
  end
  return result
end

function Fixture.nativeCalls(self: Fixture, method: string): { native.InputCall }
  return matching(self.native.events.input, method)
end

function Fixture.keyboardCount(self: Fixture): number
  if not self.keyboardObserver then
    self.keyboardObserver = self.session:observe(keyboard.capability)
  end
  local observed = self.keyboardObserver
  if not observed.context:active() then
    return 0
  end
  local count = 0
  for _, registration in ipairs(observed.service:inspect().registrations) do
    if registration.kind == 'keyboard' and registration.live then
      count += 1
    end
  end
  return count
end

function Fixture.close(self: Fixture)
  self.session:close()
end

return vrUi

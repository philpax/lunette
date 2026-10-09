-- Drives real desktop pointing through the fake XR boundary and discovers current public UI geometry.

local session = require '@testing/session'
local native = require '@testing/native'
local keyboard = require '@lunette-contracts/keyboard'

local vrUi = {}
local Fixture = {}
Fixture.__index = Fixture

local function controller(fixture, hand)
  assert(hand == 'left' or hand == 'right', 'vr-ui: a hand is left or right')
  return fixture.native.events.controllers[hand]
end

-- Attaches controller input to a configuration already driven through LÖVR callbacks.
function vrUi.attach(fake)
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
function vrUi.hands(fake)
  local fixture = vrUi.attach(fake)
  fixture:pose('left', lovr.math.newMat4():translate(-5, 1.5, 0))
  fixture:tracked('left', true)
  fixture:tracked('right', true)
  return fixture
end

function vrUi.boot(entries, options)
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

function Fixture:tracked(hand, value)
  controller(self, hand).tracked = value
end

function Fixture:button(hand, button, pressed)
  controller(self, hand).buttons[button] = pressed
end

function Fixture:axis(hand, x, y)
  local state = controller(self, hand)
  state.axisX, state.axisY = x, y
end

function Fixture:pose(hand, pose)
  local state = controller(self, hand)
  state.pose:set(pose)
  state.origin = vector.pack(pose:getPosition())
  state.direction = vector.pack(pose:mul(0, 0, -1, 0)):normalize()
end

function Fixture:aim(description, x, y, hand)
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

function Fixture:step(dt)
  self.native.events.dt = dt or 0.016
  self.native.events.time += self.native.events.dt
  lovr.update(self.native.events.dt)
end

function Fixture:draw()
  return lovr.draw(self.native.events.pass)
end

function Fixture:click(description, x, y, hand)
  hand = hand or 'right'
  self:button(hand, 'trigger', false)
  self:aim(description, x, y, hand)
  self:step()
  self:button(hand, 'trigger', true)
  self:step()
  self:button(hand, 'trigger', false)
  self:step()
end

function Fixture:discover(service, name, id, itemId, ownerIdentity)
  local foundDescription, foundControl, foundItem
  for _, panel in ipairs(service:panels()) do
    local description = panel:describe()
    if description.name == name and description.visible then
      for _, control in ipairs(description.controls) do
        if control.id == id and control.enabled and (ownerIdentity == nil or control.owner == ownerIdentity) then
          assert(
            foundControl == nil,
            'vr-ui: ambiguous control ' .. name .. '/' .. id .. '; specify its owner identity'
          )
          foundDescription, foundControl = description, control
          if itemId then
            for _, item in ipairs(control.items or {}) do
              if item.id == itemId and item.enabled then
                foundItem = item
              end
            end
          end
        end
      end
    end
  end
  if foundControl and (itemId == nil or foundItem ~= nil) then
    return foundDescription, foundItem or foundControl, foundControl.owner
  end
  error('vr-ui: no visible enabled control ' .. name .. '/' .. id .. (if itemId then '/' .. itemId else ''), 2)
end

-- Aims again after each step because a panel can follow the hand that moved.
function Fixture:clickControl(service, name, id, hand, itemId, ownerIdentity)
  hand = hand or 'right'
  local function aimCurrent()
    local description, control = self:discover(service, name, id, itemId, ownerIdentity)
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

local function matching(events, kind)
  local result = {}
  for _, event in ipairs(events) do
    if event.kind == kind or event[1] == kind then
      result[#result + 1] = event
    end
  end
  return result
end

function Fixture:drawCalls(method)
  return if method then matching(self.native.events.draw, method) else table.clone(self.native.events.draw)
end

function Fixture:nativeCalls(method)
  return if method then matching(self.native.events.input, method) else table.clone(self.native.events.input)
end

function Fixture:keyboardCount()
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

function Fixture:close()
  self.session:close()
end

return vrUi

-- Animation channels: critically damped springs that settle within their motion role's duration. A spring that
-- receives a new target keeps its velocity, so a hover that ends during the lift turns around smoothly.

local records = require './records'

local motion = {}

export type Channel = { value: number, target: number, velocity: number }

-- Natural frequency that brings a critically damped spring within 2% of its target in the duration.
local SETTLE = 5.8

function motion.channel(value: number): Channel
  return { value = value, target = value, velocity = 0 }
end

-- Advances a channel, answering whether it moved. A zero duration snaps, as reduced motion asks.
function motion.step(channel: Channel, dt: number, duration: number): boolean
  local offset = channel.value - channel.target
  if offset == 0 and channel.velocity == 0 then
    return false
  end
  if duration <= 0 or (math.abs(offset) < 1e-6 and math.abs(channel.velocity) < 1e-5) then
    channel.value, channel.velocity = channel.target, 0
    return true
  end
  local omega = SETTLE / duration
  -- The exact solution of the critically damped spring over the step, so a long frame cannot overshoot.
  local decay = math.exp(-omega * dt)
  local slope = channel.velocity + omega * offset
  channel.value = channel.target + (offset + slope * dt) * decay
  channel.velocity = (channel.velocity - omega * slope * dt) * decay
  return true
end

-- The channels of a node, created at rest on first use.
function motion.of(node: records.Node, name: string, initial: number): Channel
  local channel = node.channels[name]
  if not channel then
    channel = motion.channel(initial)
    node.channels[name] = channel
  end
  return channel
end

-- Advances every node's channels and the lift that hover and press drive, answering whether anything moved.
function motion.panel(panel: records.Panel, dt: number, duration: number): boolean
  local moving = false
  for _, node in panel.nodes do
    local lift = motion.of(node, 'elevation', 0)
    lift.target = node.liftTarget
    if motion.step(lift, dt, duration) then
      moving = true
    end
    node.lift = lift.value
    for name, channel in node.channels do
      if name ~= 'elevation' and motion.step(channel, dt, duration) then
        moving = true
        if name ~= 'opacity' then
          node.primitives = nil
        end
      end
    end
  end
  local fade = panel.fade
  if fade and motion.step(fade, dt, duration) then
    moving = true
  end
  for index = #panel.ghosts, 1, -1 do
    local ghost = panel.ghosts[index]
    motion.step(ghost.opacity, dt, duration)
    if ghost.opacity.value <= 0.01 then
      table.remove(panel.ghosts, index)
    end
    moving = true
  end
  return moving
end

return motion

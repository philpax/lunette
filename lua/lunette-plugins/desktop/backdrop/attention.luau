-- Observes the nearest offered surface without changing focus, input, or shared panel highlights.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local panels = require '@lunette-contracts/panels'
local surfaces = require '@lunette-contracts/surfaces'
local picking = require '@lunette-plugins/interaction/picking'
local passState = require '@lunette-plugins/pass-state'
local selection = require './selection'

local attention = {}
export type Ray = { read origin: vector, read direction: vector, read source: 'eye' | 'head' }
export type Dwell = {
  candidate: lunette.Process?,
  elapsed: number,
  pending: lunette.Process?,
  raySource: ('eye' | 'head')?,
  revision: number,
  frozen: boolean,
}
export type Badge = { read panel: panels.WindowPanel, read progress: number, read selected: boolean }
local reset: (Dwell) -> ()
local target: (surfaces.Surface?, panels.Service) -> panels.WindowPanel?
local drawBadge: (Pass, Badge) -> ()
local finiteVector: (vector) -> boolean

function attention.new(): Dwell
  return { candidate = nil, elapsed = 0, pending = nil, raySource = nil, revision = -1, frozen = false }
end

-- Called in pointing after current geometry is established. Delivery waits until the next input phase.
function attention.observe(dwell: Dwell, choice: selection.State, ray: Ray?, process: lunette.Process?, dt: number): ()
  local source = if ray then ray.source else nil
  if dwell.revision ~= choice.revision or dwell.raySource ~= source or dwell.frozen ~= choice.frozen then
    reset(dwell)
  end
  dwell.revision, dwell.raySource, dwell.frozen = choice.revision, source, choice.frozen
  if choice.mode ~= 'attention' or choice.frozen or ray == nil or process == nil or process.dead then
    reset(dwell)
    return
  end
  if dwell.candidate ~= process then
    reset(dwell)
    dwell.candidate = process
  end
  local elapsed = if dt == dt and dt > 0 and dt < math.huge then dt else 0
  dwell.elapsed = math.min(dwell.elapsed + elapsed, choice.dwell)
  if dwell.elapsed >= choice.dwell then
    dwell.pending = process
  end
end

function attention.commit(dwell: Dwell, choice: selection.State): ()
  local pending = dwell.pending
  dwell.pending = nil
  if pending and dwell.revision == choice.revision and not choice.frozen then
    choice:attend(pending)
  end
end

function attention.ray(): Ray?
  local eye = lovr.headset.getFeatures().eyeTracking
  local device: Device = if eye then 'eye/gaze' else 'head'
  if not lovr.headset.isTracked(device) then
    return nil
  end
  local pose = lovr.math.newMat4(lovr.headset.getPose(device))
  local origin = vector.pack(pose:getPosition())
  local dx, dy, dz = pose:mul(0, 0, -1, 0)
  local direction = vector.pack(dx, dy, dz)
  if not finiteVector(origin) or not finiteVector(direction) or direction:length() == 0 then
    return nil
  end
  return { origin = origin, direction = direction, source = if eye then 'eye' else 'head' }
end

function attention.attach(context: plugin.Context, choice: selection.State): ()
  local child = plugin.consumer<<{}, {}>> {
    name = 'desktop/backdrop/attention',
    requires = { frame.capability, panels.capability, surfaces.capability },
    init = function(childContext: plugin.Context, _settings: {}): ()
      local frames: frame.Service = childContext:require(frame.capability)
      local panelService: panels.Service = childContext:require(panels.capability)
      local offered: surfaces.Service = childContext:require(surfaces.capability)
      local dwell = attention.new()
      local badge: Badge? = nil
      childContext:effect(function(): () -> ()
        choice.attentionAvailable = true
        return function(): ()
          choice.attentionAvailable = false
          reset(dwell)
          badge = nil
        end
      end)
      frames:onUpdate(childContext, {
        phase = 'input',
        order = -100,
        run = function(): ()
          local ray = attention.ray()
          if ray == nil or ray.source ~= dwell.raySource then
            reset(dwell)
          end
          attention.commit(dwell, choice)
        end,
      })
      frames:onUpdate(childContext, {
        phase = 'pointing',
        order = 100,
        run = function(dt: number): ()
          local ray = attention.ray()
          local hit = if ray then picking.pick(offered:all(), ray.origin, ray.direction, 100) else nil
          local panel = target(hit, panelService)
          local process = if panel then panel.source.process else nil
          attention.observe(dwell, choice, ray, process, dt)
          badge = if panel
              and process
              and not process.dead
              and choice.mode == 'attention'
              and not choice.frozen
            then { panel = panel, progress = dwell.elapsed / choice.dwell, selected = choice.attended == process }
            else nil
        end,
      })
      frames:onDraw(childContext, {
        phase = 'feedback',
        run = function(pass: Pass): ()
          local current = badge
          if current and not current.panel.dead and not current.panel.hidden and not current.panel.source.dead then
            drawBadge(pass, current)
          end
        end,
      })
    end,
  }
  context:child(child.definition)
end

reset = function(dwell: Dwell): ()
  dwell.candidate, dwell.pending, dwell.elapsed = nil, nil, 0
end

target = function(hit: surfaces.Surface?, service: panels.Service): panels.WindowPanel?
  if hit == nil then
    return nil
  end
  for _, panel in service:all() do
    if panel == hit and panel.kind == 'window' and not panel.dead and not panel.hidden and not panel.source.dead then
      return panel
    end
  end
  return nil
end

-- Feedback is outside the owning panel and is never offered as an input surface.
drawBadge = function(pass: Pass, badge: Badge): ()
  local panel = badge.panel
  passState.withRestore(pass, function(): ()
    pass:setDepthTest 'none'
    pass:setDepthWrite(false)
    pass:setShader 'unlit'
    pass:setColor(if badge.selected then 0.25 else 0.75, 0.85, 0.75, 0.9)
    local pose = lovr.math.newMat4(panel.pose):translate(panel.width / 2 + 0.08, panel.height / 2 + 0.06, 0.01)
    pose:scale(0.1, 0.035, 1)
    pass:plane(pose)
    if not badge.selected and badge.progress > 0 then
      local progress = math.clamp(badge.progress, 0, 1)
      local fill = lovr.math
        .newMat4(panel.pose)
        :translate(panel.width / 2 + 0.03 + 0.05 * progress, panel.height / 2 + 0.06, 0.012)
        :scale(0.1 * progress, 0.018, 1)
      pass:setColor(0.1, 0.3, 0.25, 1)
      pass:plane(fill)
    end
  end)
end

finiteVector = function(value: vector): boolean
  return value.x == value.x
    and value.y == value.y
    and value.z == value.z
    and math.max(math.abs(value.x), math.abs(value.y), math.abs(value.z)) < math.huge
end

return attention

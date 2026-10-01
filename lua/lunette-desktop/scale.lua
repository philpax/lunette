-- Output scale for the panels in the scene.
--
-- Every frame, after the scene and the pointers have moved, the consumer
-- finds each output's nearest shown window panel, measures the distance from
-- the head to the panel's centre, and gives it to the output's chooser. It
-- sets the scale the chooser answers with `output:setMode` when the scale
-- changes, so a client re-lays-out only when its output crosses a step.
--
-- An output is a window's `window.output`, which several windows may share; a
-- shared output takes the scale of the nearest of them, so the nearest panel
-- is sharp and the others render more pixels than their distance needs, which
-- is cheaper than the nearest one being blurred. An output with no shown
-- window panel keeps its scale. Hidden panels give no distance, because nobody
-- sees them, and monitor panels give none, because a monitor's scale is its
-- host's and not an output's. Nothing is done while the headset reports no
-- head position.
--
-- Unloading sets every output this activation changed back to the scale it
-- had before the first change, unless its scale is no longer the one this
-- activation set, which means something else has set it since.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local panels = require '@lunette-contracts/panels'
local scale = require '@lunette-contracts/scale'

-- One output the consumer has chosen for: its latest handle, its chooser,
-- the scale it had before the first change, and the scale last set.
type Scaled = {
  output: lunette.Output,
  chooser: scale.Chooser,
  original: number?,
  applied: number?,
}

-- The nearest shown panel an output's clients are on this frame.
type Nearest = {
  output: lunette.Output,
  distance: number,
}

local required: plugin.Declaration = {
  frame = frame.capability,
  panels = panels.capability,
  scale = scale.capability,
}

-- Where the head is, or nothing when the headset reports no position.
local function headPosition(): (number?, number?, number?)
  local headset = lovr.headset
  if not headset or not headset.getPosition then
    return nil, nil, nil
  end
  return headset.getPosition 'head'
end

return plugin.define {
  name = 'desktop/scale',
  requires = required,
  init = function(context: plugin.Context, config: {}, _publish: plugin.Publisher): ()
    -- The consumer takes no options; tuning is the scale provider's.
    plugin.options { name = 'desktop/scale', defaults = {}, config = config }
    local frameService: frame.Service = context:require(frame.capability)
    local panelService: panels.Service = context:require(panels.capability)
    local scaleService: scale.Service = context:require(scale.capability)
    local scaled: { [number]: Scaled } = {}

    local function track(id: number, output: lunette.Output): Scaled
      local entry: Scaled = { output = output, chooser = scaleService:newChooser(), original = nil, applied = nil }
      scaled[id] = entry
      return entry
    end

    local function nearestPanels(hx: number, hy: number, hz: number): { [number]: Nearest }
      local nearest: { [number]: Nearest } = {}
      for _, panel in ipairs(panelService:all()) do
        if panel.dead or panel.hidden or panel.kind ~= 'window' then
          continue
        end
        local window = panel.source
        local output = if window.dead then nil else window.output
        if not output or output.dead then
          continue
        end
        local x, y, z = panel.pose:getPosition()
        local distance = math.sqrt((x - hx) ^ 2 + (y - hy) ^ 2 + (z - hz) ^ 2)
        local held = nearest[output.id]
        if not held or distance < held.distance then
          nearest[output.id] = { output = output, distance = distance }
        end
      end
      return nearest
    end

    frameService:onUpdate(context, {
      phase = 'overlay',
      run = function(_dt: number)
        local hx, hy, hz = headPosition()
        if hx == nil or hy == nil or hz == nil then
          return
        end
        for id, near in nearestPanels(hx, hy, hz) do
          local entry: Scaled = scaled[id] or track(id, near.output)
          entry.output = near.output
          local chosen = entry.chooser:choose(near.distance)
          local current = entry.applied or near.output.scale
          if chosen ~= current then
            if entry.original == nil then
              entry.original = near.output.scale
            end
            near.output:setMode { scale = chosen }
            entry.applied = chosen
          end
        end
        for id, entry in table.clone(scaled) do
          if entry.output.dead then
            scaled[id] = nil
          end
        end
      end,
    })

    context:effect(function(): () -> ()
      return function(): ()
        for id, entry in table.clone(scaled) do
          scaled[id] = nil
          local output, original = entry.output, entry.original
          if original ~= nil and not output.dead and output.scale == entry.applied then
            output:setMode { scale = original }
          end
        end
      end
    end)
  end,
}

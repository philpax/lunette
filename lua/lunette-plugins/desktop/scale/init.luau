-- Each output uses its nearest shown window panel. On unload, the consumer restores the original scale when no other consumer changed it.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local schema = require '@lunette-plugin/schema'
local frame = require '@lunette-contracts/frame'
local panels = require '@lunette-contracts/panels'
local scale = require '@lunette-contracts/scale'

local descriptor = schema.object {}
export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

type Scaled = {
  output: lunette.Output,
  chooser: scale.Chooser,
  original: number?,
  applied: number?,
}

type Nearest = {
  output: lunette.Output,
  distance: number,
}

local required: plugin.Declaration = {
  frame = frame.capability,
  panels = panels.capability,
  scale = scale.capability,
}

local function headPosition(): (number?, number?, number?)
  local headset = lovr.headset
  if not headset or not headset.getPosition then
    return nil, nil, nil
  end
  return headset.getPosition 'head'
end

return plugin.consumer<<Config, Settings>>({
  name = 'desktop/scale',
  requires = required,
  schema = descriptor,
  init = function(context: plugin.Context, _settings: Settings): ()
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
}).definition

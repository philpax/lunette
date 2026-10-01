-- The ARC provider. It is pure layout policy over the TAGS panel vocabulary.

local plugin = require '@lunette-plugin'
local contracts = require '@lunette-contracts/layout'
local tagsContract = require '@lunette-contracts/tags'
local surfaceContract = require '@lunette-contracts/surface'

export type Service = contracts.ArcService
export type Target = contracts.Target
export type Options = contracts.Options
export type Panel = contracts.Panel

local function angles(service: Service, count: number, options: Options?): { number }
  if type(count) ~= 'number' or count ~= math.floor(count) or count < 0 then
    error('layout.arc: a count is a whole number of panels, not ' .. tostring(count), 3)
  end
  local settings: Options = options or {}
  local step = settings.step or service.TUNING.step
  local span = settings.span or service.TUNING.span
  local placed: { number } = {}
  if count == 0 then
    return placed
  end
  if count > 1 and step * (count - 1) > span then
    step = span / (count - 1)
  end
  local first = -step * (count - 1) / 2
  for index = 1, count do
    placed[index] = first + step * (index - 1)
  end
  return placed
end

local function poses(service: Service, count: number, options: Options?): { Mat4 }
  local settings: Options = options or {}
  local radius = settings.radius or service.TUNING.radius
  local center = settings.center or service.TUNING.center
  local placed: { Mat4 } = {}
  for index, angle in ipairs(service:angles(count, options)) do
    placed[index] = lovr.math
      .newMat4()
      :translate(center[1] - math.sin(angle) * radius, center[2], center[3] - math.cos(angle) * radius)
      :rotate(angle, 0, 1, 0)
  end
  return placed
end

local function init(context: plugin.Context): Service
  local tags: tagsContract.Service = context:require(tagsContract.capability)
  -- Frozen, so no consumer can retune the layout another consumer applies.
  local tuning: contracts.Tuning = table.freeze {
    radius = 1.6,
    step = 0.55,
    span = math.pi * 1.2,
    center = table.freeze { 0, 1.5, 0 },
  }
  local service: Service
  local implementation = {
    TUNING = tuning,
    angles = function(_self: Service, count: number, options: Options?): { number }
      return angles(service, count, options)
    end,
    poses = function(_self: Service, count: number, options: Options?): { Mat4 }
      return poses(service, count, options)
    end,
    apply = function(_self: Service, target: Target, options: Options?): { Panel }
      local selected = tags:panelsOf(target)
      local placed = poses(service, #selected, options)
      for index, panel in ipairs(selected) do
        local surface: surfaceContract.Surface = panel
        local setPose = surface.setPose
        if setPose then
          setPose(surface, placed[index])
        end
      end
      return selected
    end,
    __call = function(_self: Service, target: Target, options: Options?): { Panel }
      return service:apply(target, options)
    end,
  }
  service = setmetatable(implementation, {
    __call = function(self: Service, target: Target, options: Options?): { Panel }
      return self:apply(target, options)
    end,
  })
  return service
end

return init

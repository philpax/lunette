-- The base requires only frame; optional response, attention, and controls have independent owner-scoped lifetimes.
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local audio = require '@lunette-contracts/audio'
local config = require '@lunette-plugins/desktop/backdrop/config'
local model = require '@lunette-plugins/desktop/backdrop/model'
local draw = require '@lunette-plugins/desktop/backdrop/draw'
local selection = require '@lunette-plugins/desktop/backdrop/selection'
local responseChild = require '@lunette-plugins/desktop/backdrop/response-child'
local sourceControls = require '@lunette-plugins/desktop/backdrop/source-controls'

local backdrop = {}
export type Config = config.Config
export type Settings = config.Settings
export type Options = Config & { read name: string? }
export type Controls = {
  read enabled: () -> boolean,
  read setEnabled: (boolean) -> (),
  read source: () -> audio.Source?,
  read choice: selection.State,
}
export type Attach = (plugin.Context, model.State, Controls, Settings) -> ()
export type Factory = {
  read definition: plugin.Definition<Config>,
  read controls: Controls,
  read choice: selection.State,
}
local create: (Options, Attach?) -> Factory
local processStatus: (plugin.Context, selection.State) -> ()

-- Choices belong to one definition and survive provider reactivation, but not a new definition or source reload.
function backdrop.create(given: Options?, attach: Attach?): Factory
  local options: Options = given or {}
  return create(options, attach)
end

function backdrop.define(given: Options): plugin.Definition<Config>
  return create(given, nil).definition
end

create = function(given: Options, attach: Attach?): Factory
  local active: model.State? = nil
  local retainedEnabled: boolean? = nil
  local configuredEnabled: boolean? = nil
  local choice = selection.new()
  local controls: Controls = table.freeze {
    enabled = function(): boolean
      return if retainedEnabled == nil then given.enabled ~= false else retainedEnabled
    end,
    setEnabled = function(enabled: boolean): ()
      retainedEnabled = enabled
      if active then
        active:setEnabled(enabled)
      end
    end,
    source = function(): audio.Source?
      return choice:source()
    end,
    choice = choice,
  }
  local consumer = plugin.consumer<<Config, Settings>> {
    name = 'desktop/backdrop',
    requires = { frame.capability },
    schema = config.schema,
    init = function(context: plugin.Context, settings: Settings): ()
      local state = model.new(settings)
      choice:configure(settings)
      state:setStrengths(choice.response, choice.motion)
      if retainedEnabled == nil or (configuredEnabled ~= nil and configuredEnabled ~= settings.enabled) then
        retainedEnabled = settings.enabled
      end
      configuredEnabled = settings.enabled
      state:setEnabled(if retainedEnabled == nil then settings.enabled else retainedEnabled)
      active = state
      context:effect(function(): () -> ()
        return function(): ()
          if active == state then
            active = nil
          end
        end
      end)
      local renderer = draw.new(context, settings)
      local current = state:update(0, true)
      local headPosition = vector.pack(0, 0, 0)
      local facing: number? = nil
      local service: frame.Service = context:require(frame.capability)
      service:onUpdate(context, {
        phase = 'scene',
        run = function(dt: number): ()
          state:setStrengths(choice.response, choice.motion)
          current = state:update(dt, lovr.headset.isMainSessionVisible())
          local x, y, z = lovr.headset.getPosition 'head'
          if x == x and y == y and z == z and math.max(math.abs(x), math.abs(y), math.abs(z)) < math.huge then
            headPosition = vector.pack(x, y, z)
          end
          local dx, _dy, dz = lovr.headset.getDirection 'head'
          local reach = dx * dx + dz * dz
          if reach == reach and reach > 1e-6 and reach < math.huge then
            facing = (math.atan2(dx, dz) / (2 * math.pi)) % 1
          end
        end,
      })
      service:onDraw(context, {
        phase = 'scene',
        order = -100,
        run = function(pass: Pass): ()
          renderer.render(pass, current, headPosition)
        end,
      })
      context:child(responseChild.new(choice, state, settings, function(): boolean
        return state.visibility > 0 or (controls.enabled() and not lovr.headset.isMainSessionVisible())
      end, function(): number?
        return facing
      end))
      processStatus(context, choice)
      sourceControls.attach(context, choice, controls)
      if attach then
        attach(context, state, controls, settings)
      end
    end,
  }
  return table.freeze { definition = consumer.define(given), controls = controls, choice = choice }
end

processStatus = function(context: plugin.Context, choice: selection.State): ()
  context:child(plugin.consumer<<{}, {}>>({
    name = 'desktop/backdrop/process-status',
    requires = { audio.capability, frame.capability },
    init = function(childContext: plugin.Context, _settings: {}): ()
      local service: audio.Service = childContext:require(audio.capability)
      local frames: frame.Service = childContext:require(frame.capability)
      childContext:effect(function(): () -> ()
        return function(): ()
          choice.processStatuses = {}
        end
      end)
      frames:onUpdate(childContext, {
        phase = 'scene',
        order = 75,
        run = function(): ()
          choice.processStatuses = service:processes()
        end,
      })
    end,
  }).definition)
end

backdrop.definition = create({}, nil).definition

return backdrop

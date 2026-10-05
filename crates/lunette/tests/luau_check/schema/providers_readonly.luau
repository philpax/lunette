local lunette = require '@lunette'
local schema = require '@lunette-plugin/schema'
local plugin = require '@lunette-plugin'
local bindings = require '@lunette-contracts/bindings'
local keyboard = require '@lunette-contracts/keyboard'
local laser = require '@lunette-contracts/laser'
local rules = require '@lunette-contracts/rules'
local layouts = require '@lunette-contracts/layouts'
local tags = require '@lunette-contracts/tags'
local interaction = require '@lunette-contracts/interaction'
local keyboardConfig = require '@lunette-plugins/keyboard/config'
local laserConfig = require '@lunette-plugins/laser/config'

local strings = schema.array(schema.string()).parse { 'control' }
local ruleList = schema.array(schema.object {}).parse { {} }
local evaluate = function(_window: lunette.Window, _key: string): unknown
  return nil
end
local evaluators: rules.Evaluators =
  schema.map(schema.callback<<(lunette.Window, string) -> unknown>>(evaluate)).parse {}
local keyboardSettings = keyboardConfig.parse {}
local laserSettings = laserConfig.parse {}

local function use(
  owner: plugin.Owner,
  bindingService: bindings.Service,
  keyboardService: keyboard.Service,
  ruleService: rules.Service,
  layoutService: layouts.Service,
  tagService: tags.Service,
  laserService: laser.Service,
  pointer: interaction.Pointer,
  input: interaction.Input,
  panels: { read [number]: layouts.Panel },
  surfaces: { read [number]: interaction.Surface }
): ()
  bindingService:register(
    owner,
    { chord = { key = 't', modifiers = strings }, run = function(_press: bindings.Press): () end }
  )
  keyboardService:new(owner, {
    rows = keyboardSettings.rows,
    layers = keyboardSettings.layers,
    style = keyboardSettings.style,
  })
  ruleService:fromList(ruleList)
  ruleService:setRules(owner, { rules = ruleList })
  layoutService:apply { name = 'arc', panels = panels }
  tagService:panelsOf(panels)
  laserService:update(surfaces)
  pointer:update(input, surfaces)
end

local color: laser.Color = laserSettings.style.color
local chord: keyboard.Action = { kind = 'chord', code = 30, modifiers = strings }
return { use = use, color = color, chord = chord, evaluators = evaluators }

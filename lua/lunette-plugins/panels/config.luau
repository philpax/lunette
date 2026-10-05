local schema = require '@lunette-plugin/schema'
local contracts = require '@lunette-contracts/panels'

export type RaycastBase = (contracts.Panel, vector, vector, boolean?) -> (number?, number?, number?)
export type Raycast = (contracts.Panel, vector, vector, boolean?, RaycastBase) -> (number?, number?, number?)
export type DrawBase = (contracts.Panel, Pass) -> ()
export type Draw = (contracts.Panel, Pass, DrawBase) -> ()
export type LayerBase = (contracts.Panel, Layer) -> ()
export type ApplyLayer = (contracts.Panel, Layer, LayerBase) -> ()

local function raycast(
  target: contracts.Panel,
  origin: vector,
  direction: vector,
  backFace: boolean?,
  base: RaycastBase
): (number?, number?, number?)
  return base(target, origin, direction, backFace)
end
local function draw(target: contracts.Panel, pass: Pass, base: DrawBase): ()
  base(target, pass)
end
local function applyLayer(target: contracts.Panel, held: Layer, base: LayerBase): ()
  base(target, held)
end

local COLOR = schema.array(schema.number())
local STYLE = schema.object {
  borderThickness = schema.default(schema.number())(0.008),
  borderDepth = schema.default(schema.number())(0.001),
  borderColor = schema.default(COLOR) { 0.14, 0.14, 0.17, 0.95 },
  borderHighlightColor = schema.default(COLOR) { 0.35, 0.55, 0.95, 0.95 },
  titleHeight = schema.default(schema.number())(0.04),
  titleMargin = schema.default(schema.number())(0.02),
  titleColor = schema.default(COLOR) { 1, 1, 1, 1 },
}
local function defaultCallback<F>(callback: F): schema.Schema<F?, F>
  return schema.default(schema.callback(callback))(callback)
end

local function configuration<R, D, A>(raycastHook: R, drawHook: D, layerHook: A)
  local shape = schema.object {
    raycast = defaultCallback(raycastHook),
    draw = defaultCallback(drawHook),
    applyLayer = defaultCallback(layerHook),
  }
  return schema.object {
    style = schema.default(STYLE)(STYLE.parse {}),
    priority = schema.default(schema.number())(10),
    height = schema.default(schema.number())(0.8),
    aspect = schema.default(schema.number())(16 / 9),
    chrome = schema.default(schema.boolean())(false),
    shape = schema.default(shape)(shape.parse {}),
  }
end
local SCHEMA = configuration<<Raycast, Draw, ApplyLayer>>(raycast, draw, applyLayer)

export type Shape = {
  read raycast: Raycast,
  read draw: Draw,
  read applyLayer: ApplyLayer,
}
export type Config = schema.Input<typeof(SCHEMA)>
export type Settings = schema.Output<typeof(SCHEMA)>

return SCHEMA

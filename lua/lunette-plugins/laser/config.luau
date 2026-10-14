local lunette = require '@lunette'
local schema = require '@lunette-plugin/schema'
local contracts = require '@lunette-contracts/laser'
local interaction = require '@lunette-contracts/interaction'
local aim = require './aim'
local triggerLock = require './trigger-lock'
local style = require './style'
local input = require './input'
local dragIcon = require './drag-icon'
local clientPixels = require '@lunette-plugins/graphics/client-pixels'

-- The record a draw hook receives: the contract's laser and the provider state its drawing reads.
export type Beam = {
  read hand: contracts.Hand,
  read device: input.Device,
  read controller: input.Device,
  read seat: lunette.Seat,
  read ownsSeat: boolean,
  read readInput: (contracts.Hand) -> contracts.Input?,
  read pointer: interaction.Pointer,
  read style: style.Style,
  read input: contracts.Input?,
  -- The geometry and shaders that draw the icon of a drag the seat carries.
  read icon: dragIcon.State,
  read iconShaders: clientPixels.Shaders,
  read dead: boolean,
  read update: (Beam, { read [number]: contracts.Surface }) -> (),
  read draw: (Beam, Pass) -> (),
  read vibrate: (Beam) -> boolean,
  read destroy: (Beam) -> boolean,
}

export type ReadBase = (contracts.Hand) -> contracts.Input?
export type ReadInput = (contracts.Hand, ReadBase) -> contracts.Input?
export type DrawBase = (Beam, Pass) -> ()
export type Draw = (Beam, Pass, DrawBase) -> ()

local function readInput(hand: contracts.Hand, base: ReadBase): contracts.Input?
  return base(hand)
end
local function drawLaser(laser: Beam, pass: Pass, base: DrawBase): ()
  base(laser, pass)
end

local CONTROL = schema.enum<<DeviceButton>> {
  'trigger',
  'thumbstick',
  'thumbrest',
  'thumbtap',
  'touchpad',
  'grip',
  'menu',
  'a',
  'b',
  'x',
  'y',
  'dpup',
  'dpdown',
  'dpleft',
  'dpright',
  'shoulder',
  'nib',
}
local BUTTON = schema.enum<<lunette.PointerButton>> { 'left', 'right', 'middle', 'back', 'forward' }
local MAPPING = schema.object { control = CONTROL, button = BUTTON }
local STYLE = style.configuration
local function defaultCallback<F>(callback: F): schema.Schema<F?, F>
  return schema.default(schema.callback(callback))(callback)
end
type ConfigurationShape<R, D> = {
  style: schema.Schema<schema.Input<typeof(STYLE)>?, schema.Output<typeof(STYLE)>>,
  aim: schema.Schema<schema.Input<typeof(aim.schema)>?, schema.Output<typeof(aim.schema)>>,
  triggerLock: schema.Schema<schema.Input<typeof(triggerLock.schema)>?, schema.Output<typeof(triggerLock.schema)>>,
  buttons: schema.Schema<{ schema.Input<typeof(MAPPING)> }?, { read [number]: schema.Output<typeof(MAPPING)> }>,
  readInput: schema.Schema<R?, R>,
  draw: schema.Schema<D?, D>,
}
local function configuration<R, D>(
  reader: R,
  drawing: D
): schema.Schema<
  schema.ObjectInput<ConfigurationShape<R, D>>,
  schema.ObjectOutput<ConfigurationShape<R, D>>
>
  return schema.object {
    style = schema.default(STYLE)(STYLE.parse {}),
    aim = schema.default(aim.schema)(aim.schema.parse {}),
    triggerLock = schema.default(triggerLock.schema)(triggerLock.schema.parse {}),
    buttons = schema.default(schema.array(MAPPING)) { { control = 'trigger', button = 'left' } },
    readInput = defaultCallback(reader),
    draw = defaultCallback(drawing),
  }
end
local SCHEMA = configuration<<ReadInput, Draw>>(readInput, drawLaser)

export type Config = schema.Input<typeof(SCHEMA)>
export type Settings = schema.Output<typeof(SCHEMA)>

return { schema = SCHEMA }

local schema = require '@lunette-plugin/schema'
local contracts = require '@lunette-contracts/laser'
local aim = require './aim'
local triggerLock = require './trigger-lock'
local style = require './style'

export type ReadBase = (contracts.Hand) -> contracts.Input?
export type ReadInput = (contracts.Hand, ReadBase) -> contracts.Input?
export type DrawBase = (contracts.Laser, Pass) -> ()
export type Draw = (contracts.Laser, Pass, DrawBase) -> ()

local function readInput(hand: contracts.Hand, base: ReadBase): contracts.Input?
  return base(hand)
end
local function drawLaser(laser: contracts.Laser, pass: Pass, base: DrawBase): ()
  base(laser, pass)
end

local CONTROL = schema.union(
  schema.literal<<'trigger'>> 'trigger',
  schema.union(
    schema.literal<<'thumbstick'>> 'thumbstick',
    schema.union(
      schema.literal<<'thumbrest'>> 'thumbrest',
      schema.union(
        schema.literal<<'thumbtap'>> 'thumbtap',
        schema.union(
          schema.literal<<'touchpad'>> 'touchpad',
          schema.union(
            schema.literal<<'grip'>> 'grip',
            schema.union(
              schema.literal<<'menu'>> 'menu',
              schema.union(
                schema.literal<<'a'>> 'a',
                schema.union(
                  schema.literal<<'b'>> 'b',
                  schema.union(
                    schema.literal<<'x'>> 'x',
                    schema.union(
                      schema.literal<<'y'>> 'y',
                      schema.union(
                        schema.literal<<'dpup'>> 'dpup',
                        schema.union(
                          schema.literal<<'dpdown'>> 'dpdown',
                          schema.union(
                            schema.literal<<'dpleft'>> 'dpleft',
                            schema.union(
                              schema.literal<<'dpright'>> 'dpright',
                              schema.union(schema.literal<<'bumper'>> 'bumper', schema.literal<<'nib'>> 'nib')
                            )
                          )
                        )
                      )
                    )
                  )
                )
              )
            )
          )
        )
      )
    )
  )
)
local BUTTON = schema.union(
  schema.literal<<'left'>> 'left',
  schema.union(
    schema.literal<<'right'>> 'right',
    schema.union(
      schema.literal<<'middle'>> 'middle',
      schema.union(schema.literal<<'back'>> 'back', schema.literal<<'forward'>> 'forward')
    )
  )
)
local MAPPING = schema.object { control = CONTROL, button = BUTTON }
local STYLE = style.configuration
local function defaultCallback<F>(callback: F): schema.Schema<F?, F>
  return schema.default(schema.callback(callback))(callback)
end
local function configuration<R, D>(reader: R, drawing: D)
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

return SCHEMA

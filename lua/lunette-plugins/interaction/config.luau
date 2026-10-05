local schema = require '@lunette-plugin/schema'
local contracts = require '@lunette-contracts/interaction'

export type DriveBase = (contracts.Pointer, contracts.Input, { read [number]: contracts.Surface }) -> ()
export type Drive = (contracts.Pointer, contracts.Input, { read [number]: contracts.Surface }, DriveBase) -> ()
export type ConstrainBase = (contracts.Surface, Mat4) -> Mat4
export type Constrain = (contracts.Surface, Mat4, ConstrainBase) -> Mat4

local function drive(
  pointer: contracts.Pointer,
  input: contracts.Input,
  surfaces: { read [number]: contracts.Surface },
  base: DriveBase
): ()
  base(pointer, input, surfaces)
end

local function constrain(surface: contracts.Surface, pose: Mat4, base: ConstrainBase): Mat4
  return base(surface, pose)
end

local TUNING = schema.object {
  reach = schema.default(schema.number())(8),
  grabDeadZone = schema.default(schema.number())(0.006),
  scrollScale = schema.default(schema.number())(900),
  scrollDeadZone = schema.default(schema.number())(0.2),
  reachScale = schema.default(schema.number())(1.2),
  reachMinimum = schema.default(schema.number())(0.2),
  reachMaximum = schema.default(schema.number())(6),
  resizeMinimum = schema.default(schema.number())(0.15),
  resizeMaximum = schema.default(schema.number())(4),
}
local function defaultCallback<F>(callback: F): schema.Schema<F?, F>
  return schema.default(schema.callback(callback))(callback)
end

local function configuration<D, C>(driveHook: D, constrainHook: C)
  return schema.object {
    tuning = schema.default(TUNING)(TUNING.parse {}),
    focusOnPress = schema.default(schema.boolean())(true),
    drive = defaultCallback(driveHook),
    constrain = defaultCallback(constrainHook),
  }
end
local SCHEMA = configuration<<Drive, Constrain>>(drive, constrain)

export type Config = schema.Input<typeof(SCHEMA)>
export type Settings = schema.Output<typeof(SCHEMA)>

return SCHEMA

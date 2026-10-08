-- Surface types use shared recursive definitions without importing the interaction service.

local vocabulary = require '@lunette-contracts/vocabulary'

local surface = {}

export type Surface = vocabulary.Surface
export type Pointer = vocabulary.Pointer
export type Movable = vocabulary.Movable
export type PointerEvent = vocabulary.PointerEvent
export type CancelReason = vocabulary.CancelReason
export type FrameColor = vocabulary.FrameColor
export type FrameStyle = vocabulary.FrameStyle
export type FrameAttachment = vocabulary.FrameAttachment

return surface

-- Neutral surface vocabulary shared by panels, pointers, and keyboards. The recursive shapes live in
-- vocabulary.luau so providers can name receivers without importing the interaction service.

local vocabulary = require '@lunette-contracts/vocabulary'

local surface = {}

export type Surface = vocabulary.Surface
export type Pointer = vocabulary.Pointer
export type Movable = vocabulary.Movable

return surface

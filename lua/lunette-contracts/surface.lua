-- Neutral surface vocabulary shared by panels, pointers, and keyboards.
--
-- This module has no capability and no state. The recursive shapes live in the
-- types-only vocabulary sibling so providers can name checked receivers without
-- importing the interaction service.

local vocabulary = require '@lunette-contracts/vocabulary'

local surface = {}

export type Surface = vocabulary.Surface
export type Pointer = vocabulary.Pointer
export type Movable = vocabulary.Movable

return surface

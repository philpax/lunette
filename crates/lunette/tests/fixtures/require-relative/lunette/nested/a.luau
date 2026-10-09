local sibling = require './b'
local parent = require '../b'

local siblingWhere: 'nested/b' = sibling.where
local parentWhere: 'b' = parent.where

return { where = 'nested/a' :: 'nested/a', sibling = siblingWhere, parent = parentWhere, siblingModule = sibling }

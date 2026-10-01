-- An init file is the module its directory names, so `./` reaches a sibling
-- of the directory and `@self` reaches into it.
local helper = require '@self/helper'
local sibling = require './sibling'

local helperWhere: 'tools/helper' = helper.where
local siblingWhere: 'sibling' = sibling.where

return { helper = helperWhere, sibling = siblingWhere }

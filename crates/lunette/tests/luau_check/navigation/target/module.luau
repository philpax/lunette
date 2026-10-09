local sibling = require './sibling'
local parent = require '../parent'
local dependency = require '@chain/dependency'
local current = require '@current'
local endpoint: 'linked-init' = current.where
return { sibling = sibling.where, parent = parent.where, dependency = dependency.where, endpoint = endpoint }

local linked = require './nested/linked/module'
local init = require './tools'
local parentEndpoint = require './tools/child/main'
local endpoint: 'parent-init' = parentEndpoint.where

local sibling: 'linked-sibling' = linked.sibling
local parent: 'lexical-parent' = linked.parent
local dependency: 'target-alias' = linked.dependency
local self: 'init-helper' = init.helper

return { sibling = sibling, parent = parent, dependency = dependency, helper = self, endpoint = endpoint }

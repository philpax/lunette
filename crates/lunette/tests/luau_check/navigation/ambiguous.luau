local extensions = require './ambiguous/extensions'
local directory = require './ambiguous/directory'
local init = require './ambiguous/init'
local bare = require './ambiguous/bare'
local missing = require './absent'
return { extensions, directory, init, bare, missing }

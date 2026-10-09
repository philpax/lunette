local extensions = require './ambiguous/extensions' -- reject: unsupported path.
local directory = require './ambiguous/directory' -- reject: unsupported path.
local init = require './ambiguous/init' -- reject: unsupported path.
local bare = require './ambiguous/bare' -- reject: unsupported path.
local missing = require './absent' -- reject: unsupported path.
return { extensions, directory, init, bare, missing }

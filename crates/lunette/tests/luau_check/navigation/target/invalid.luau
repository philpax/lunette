local bare = require '@bare' -- reject: unsupported path.
local collision = require '@collision' -- reject: unsupported path.
local missing = require '@missing' -- reject: unsupported path.
local reserved = require '@reserved' -- reject: unsupported path.
return { bare, collision, missing, reserved }

-- Requires modules by relative path from a nested directory, and quits with a status naming the
-- first wrong resolution. The top-level `b.luau` is what a root-relative resolution would load.

-- Protected, because an error at the top level would start safe mode, which does not quit.
local function modules()
  return require './nested/a', require './tools', require './b', require './nested/b'
end

function lovr.load(): ()
  local ok, nested, tools, top, nestedB = pcall(modules)
  if not ok then
    print(nested)
    lovr.event.quit(10)
    return
  end
  local status = 9
  if nested.where ~= 'nested/a' then
    status = 11
  elseif nested.sibling ~= 'nested/b' then
    status = 12
  elseif nested.parent ~= 'b' then
    status = 13
  elseif tools.helper ~= 'tools/helper' then
    status = 14
  elseif tools.sibling ~= 'sibling' then
    status = 15
  elseif top.where ~= 'b' then
    status = 16
  elseif nested.siblingModule ~= nestedB then
    status = 17
  end
  lovr.event.quit(status)
end

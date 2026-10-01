-- Requires modules by relative path from a nested directory.
--
-- The checker resolves `./` and `../` against the requiring file, as Luau's
-- require-by-string rules say, and the session resolves them the same way.
-- Each module answers where it is, typed as a singleton, so the checker
-- reports a module that resolved to the wrong file, and the session quits with
-- a status naming the first assertion that did not hold.
--
-- The top-level `b.luau` is the file a session that resolved against the
-- configuration root would load for `nested/a.luau`'s `./b`. The module
-- `nested/a.luau` reaches as `./b` is the one `main.luau` reaches as
-- `./nested/b`, because both are cached under the resolved name.

-- The requires run under a protected call, so a module that does not
-- resolve quits with a status. An error at the top level would start safe
-- mode, which does not quit.
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

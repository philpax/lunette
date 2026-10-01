-- Mirrors LÖVR's module-to-filename normalization while preserving literal cache keys.
function require(request)
  local cached = package.loaded[request]
  if cached ~= nil then
    return cached
  end
  local name = request:gsub('%.', '/'):gsub('/+', '/'):gsub('^/', '')
  local loader = assert(modules[name], 'unknown module: ' .. request .. ' (' .. name .. ')')
  local value = loader()
  if value == nil then
    value = true
  end
  package.loaded[request] = value
  return value
end

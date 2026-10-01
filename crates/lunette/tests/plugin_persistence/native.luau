-- Native claims and matrices are the unmanaged boundary; providers and persistence are real.
local native = require '@lunette'
native.claimLayer = function(options)
  local claim = { dead = false, granted = false, layer = false, width = options.width, height = options.height }
  function claim:release()
    if self.dead then
      return false
    end
    self.dead = true
    return true
  end
  return claim
end

lovr = { math = {} }
function lovr.math.newMat4(other)
  local matrix = { elements = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 } }
  function matrix:set(...)
    local first = ...
    self.elements = if type(first) == 'table' then table.clone(first.elements) else { ... }
    assert(#self.elements == 16, 'a matrix has sixteen elements')
    return self
  end
  function matrix:translate(x, y, z)
    self.elements[13] += x
    self.elements[14] += y
    self.elements[15] += z
    return self
  end
  function matrix:unpack(_raw)
    return table.unpack(self.elements)
  end
  function matrix:getPosition()
    return self.elements[13], self.elements[14], self.elements[15]
  end
  if other then
    matrix:set(other)
  end
  return matrix
end

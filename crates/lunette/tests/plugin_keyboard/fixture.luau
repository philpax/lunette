local native = require '@lunette'
native.seats = function()
  return {}
end
allocations = 0
local function matrix(value)
  allocations += 1
  local pose = { x = value and value.x or 0, y = value and value.y or 0, z = value and value.z or -1 }
  function pose:set(other)
    self.x, self.y, self.z = other.x, other.y, other.z
    return self
  end
  function pose:getPosition()
    return self.x, self.y, self.z
  end
  function pose:getOrientation()
    return 0, 0, 1, 0
  end
  function pose:translate()
    return self
  end
  function pose:scale()
    return self
  end
  function pose:invert()
    self.x, self.y, self.z = -self.x, -self.y, -self.z
    return self
  end
  function pose:mul(x, y, z, w)
    return x + self.x * w, y + self.y * w, z + self.z * w
  end
  return pose
end
lovr = { math = { newMat4 = matrix, mat4 = matrix }, graphics = {} }

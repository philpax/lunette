local native = require '@lunette'
claims = {}
native.claimLayer = function(options)
  local claim = { dead = false, granted = false, layer = false, width = options.width, height = options.height }
  function claim:release()
    if self.dead then
      return false
    end
    self.dead = true
    return true
  end
  table.insert(claims, claim)
  return claim
end
lovr = { math = {} }
function lovr.math.newMat4(other)
  local pose = { x = 0, y = 0, z = 0, angle = 0 }
  function pose:set(value)
    self.x, self.y, self.z, self.angle = value.x, value.y, value.z, value.angle
    return self
  end
  function pose:translate(x, y, z)
    self.x, self.y, self.z = x, y, z
    return self
  end
  function pose:rotate(angle)
    self.angle = angle
    return self
  end
  if other then
    pose:set(other)
  end
  return pose
end
window = { id = 1, dead = false, width = 800, height = 600, appId = 'fixture', title = 'Fixture', opaque = false }

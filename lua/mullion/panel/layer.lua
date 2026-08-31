-- The composition layer a window panel draws on.
--
-- This module holds a claim against the fixed-size pool, aligns the claim
-- with the source, and applies the granted layer. `mullion.panel` holds the
-- pose, the size, and the source. The runtime grants and revokes claims on
-- frame boundaries, never mid-frame (docs/dev/lua-api.md#layer-claims), so this
-- module reads `claim.granted` each update and does not handle
-- `lunette.onLayerGranted`.
--
-- A monitor panel never holds a claim. `lunette.claimLayer` takes a window
-- and nothing else, so a mirrored screen has no way to request a layer and
-- draws as a quad. No monitor form of the call exists, so the module cannot
-- claim a layer for a mirrored screen.

local lunette = require '@lunette'

local signal = require '@mullion/signal'

local layer = {}

-- A layer claim, as `lunette.claimLayer` answers. The type states the shape,
-- because a configuration may provide a claim of its own that is not the
-- native `lunette.Claim`.
export type Claim = {
  read granted: boolean?,
  read width: number?,
  read height: number?,
  read layer: Layer | false,
  -- The result is unused. `...any` covers a release that answers nothing and
  -- the native release, which answers a boolean.
  read release: (any) -> ...any,
}
-- What the layer half of a panel reads and writes.
--
-- The fields it writes are named as they are on a panel, because it writes
-- them: a claim, the size last applied to the layer, and whether the panel is
-- on one. The rest it reads.
export type Claimant = {
  read kind: 'window' | 'monitor',
  read source: lunette.Window | lunette.Monitor,
  read pose: Mat4,
  read width: number,
  read height: number,
  read priority: number,
  claim: Claim?,
  appliedWidth: number?,
  appliedHeight: number?,
  granted: boolean,
}

-- Aligns the layer claim with the source's pixel size.
--
-- A claim specifies a key, and the key carries the size, so the pool cannot
-- enlarge a grant in place. When a window's client resizes past the layer the
-- claim holds, the claim is released and remade on a larger rung. The new
-- claim holds nothing until the next grant boundary, so the panel draws as a
-- quad for a frame or two.
function layer.sync(self: Claimant, pixelWidth: number, pixelHeight: number)
  if self.kind ~= 'window' then
    return
  end

  if self.claim then
    local layerWidth: number? = self.claim.width
    local layerHeight: number? = self.claim.height
    -- A layer smaller than the source would crop it.
    if layerWidth and layerHeight and (pixelWidth <= layerWidth and pixelHeight <= layerHeight) then
      return
    end
    self.claim:release()
    self.claim = nil
    signal.setProperty(self, 'granted', false)
    self.appliedWidth, self.appliedHeight = nil, nil
  end

  self.claim = lunette.claimLayer {
    window = self.source :: lunette.Window,
    width = pixelWidth,
    height = pixelHeight,
    priority = self.priority,
  }
end

-- Applies the layer this panel holds, and answers whether the panel is on one.
--
-- Called each update after `sync`, with the source's pixel size.
function layer.drive(self: Claimant, pixelWidth: number, pixelHeight: number): boolean
  if not self.claim then
    return false
  end

  local granted = self.claim.granted and true or false
  local resized = self.appliedWidth ~= pixelWidth or self.appliedHeight ~= pixelHeight

  if not granted then
    self.appliedWidth, self.appliedHeight = nil, nil
    signal.setProperty(self, 'granted', false)
    return false
  end

  -- `claim.layer` is not cached across frames: the layer goes away on revoke,
  -- and re-acquiring it is cheap.
  local held = self.claim.layer
  if not held then
    return false
  end

  -- The viewport is set on every grant and on every resize
  -- (docs/dev/rendering.md#the-layer-pool). The size ladder quantises upwards, so
  -- the layer is usually larger than the source and the blit lands at the
  -- layer's origin. The viewport excludes the margin. Without the viewport
  -- the whole layer composites. The blit clears the margin, so it draws as
  -- transparent black. An 800x600 window in a 1024x1024 layer would then be
  -- drawn squeezed into the top-left corner of a square.
  if resized or not self.granted then
    held:setViewport(0, 0, pixelWidth, pixelHeight)
    self.appliedWidth, self.appliedHeight = pixelWidth, pixelHeight
  end

  held:setPosition(self.pose:getPosition())
  -- `Mat4:getOrientation` returns an angle and an axis. `luax_readquat` takes
  -- four numbers. `lovr.math.quat` does not construct from a `Mat4`, so the
  -- conversion happens at this boundary.
  held:setOrientation(self.pose:getOrientation())
  held:setDimensions(self.width, self.height)

  signal.setProperty(self, 'granted', true)
  return true
end

return layer

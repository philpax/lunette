-- Composition-layer claim management for a panels provider.
--
-- The helper owns no registry state. It only coordinates the claim attached to
-- one panel, and the caller performs the provider owner check before invoking
-- the operation that may mint or replace a claim.

local lunette = require '@lunette'

local layer = {}

export type Claim = lunette.Claim

type ClaimantFields = {
  read pose: Mat4,
  read width: number,
  read height: number,
  read priority: number,
  claim: Claim?,
  appliedWidth: number?,
  appliedHeight: number?,
  granted: boolean,
}

export type Claimant =
  ClaimantFields
  & ({ read kind: 'window', read source: lunette.Window } | { read kind: 'monitor', read source: lunette.Monitor })

-- Releases a claim when it cannot hold the current source size.
function layer.sync(self: Claimant, pixelWidth: number, pixelHeight: number)
  if self.kind ~= 'window' then
    return
  end

  if self.claim then
    local layerWidth: number? = self.claim.width
    local layerHeight: number? = self.claim.height
    if layerWidth and layerHeight and (pixelWidth <= layerWidth and pixelHeight <= layerHeight) then
      return
    end
    self.claim:release()
    self.claim = nil
    self.granted = false
    self.appliedWidth, self.appliedHeight = nil, nil
  end

  self.claim = lunette.claimLayer {
    window = self.source,
    width = pixelWidth,
    height = pixelHeight,
    priority = self.priority,
  }
end

-- Applies the current grant and returns whether the panel is on a layer.
-- `place` puts the held layer where the panel is; the viewport is set here.
function layer.drive(self: Claimant, pixelWidth: number, pixelHeight: number, place: (Layer) -> ()): boolean
  if not self.claim then
    return false
  end

  local granted = self.claim.granted and true or false
  local resized = self.appliedWidth ~= pixelWidth or self.appliedHeight ~= pixelHeight
  if not granted then
    self.appliedWidth, self.appliedHeight = nil, nil
    self.granted = false
    return false
  end

  local held = self.claim.layer
  if not held then
    return false
  end

  if resized or not self.granted then
    held:setViewport(0, 0, pixelWidth, pixelHeight)
    self.appliedWidth, self.appliedHeight = pixelWidth, pixelHeight
  end

  place(held)

  self.granted = true
  return true
end

return layer

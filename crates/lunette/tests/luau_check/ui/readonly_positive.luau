local ui = require '@lunette-contracts/ui'

type RequiredLabel = { read id: string, read bounds: ui.Bounds, read label: string }
type MinimalOptions = { read id: string, read bounds: ui.Bounds }
type RequiredEnabled = { read id: string, read label: string, read enabled: boolean }
type MinimalItem = { read id: string, read label: string }
type Metadata = { read name: string, read generation: ui.Generation?, read visible: boolean? }
type ControlMetadata = { read id: string, read owner: ui.OwnerIdentity? }
type OptionalOwner = { read owner: ui.OwnerIdentity? }
type RequiredOwner = { read owner: ui.OwnerIdentity }
type NoOwner = { read id: string }

local function options(required: RequiredLabel, minimal: MinimalOptions): (ui.Options, ui.Options)
  local withLabel: ui.Options = required
  local withoutLabel: ui.Options = minimal
  return withLabel, withoutLabel
end

local function items(required: RequiredEnabled, minimal: MinimalItem): { read [number]: ui.Item }
  local enabled: ui.Item = required
  local defaultEnabled: ui.Item = minimal
  return { enabled, defaultEnabled }
end

local function describe(value: ui.Description): Metadata
  local metadata: Metadata = value
  local generation: ui.Generation = value.generation
  local kind: 'ui-generation' = generation.kind
  assert(kind == 'ui-generation')
  return metadata
end

local function inspectControl(value: ui.Control, description: ui.ControlDescription): (ControlMetadata, ControlMetadata)
  local handleMetadata: ControlMetadata = value
  local descriptionMetadata: ControlMetadata = description
  local identity: ui.OwnerIdentity = value.owner
  local kind: 'ui-owner' = identity.kind
  assert(kind == 'ui-owner' and identity == description.owner)
  return handleMetadata, descriptionMetadata
end

local function ownerCovariance(required: RequiredOwner, absent: NoOwner): (OptionalOwner, OptionalOwner)
  local present: OptionalOwner = required
  local missing: OptionalOwner = absent
  return present, missing
end

return { options, items, describe, inspectControl, ownerCovariance }

-- Owner-scoped registrations of element kinds and visuals.

local plugin = require '@lunette-plugin'
local uiHost = require '@lunette-contracts/ui-host'
local records = require './records'
local outlets = require './outlet-kinds'

local registry = {}

export type Registry = {
  -- Kind registrations per name, the base first; the newest override is current.
  kinds: { [string]: { records.Kind } },
  -- While on, every kind resolves to its base registration and every visual name to its base visual.
  defaultAppearance: boolean,
  -- Kind overrides per name, oldest first, from which the stack above each base registration is built.
  overrides: { [string]: { { owner: plugin.Owner, registration: uiHost.KindRegistration } } },
  -- Visual registrations per name, oldest first; the newest is current and receives the older ones as `base`.
  visuals: { [string]: { { owner: plugin.Owner, visual: uiHost.Visual } } },
  missing: records.Kind,
}

export type Override = { read name: string, read owner: plugin.Owner, read kind: 'kind' | 'visual' }

local REGISTRATION_FIELDS: { [string]: boolean } = {
  name = true,
  version = true,
  layout = true,
  visuals = true,
  event = true,
  elevation = true,
  response = true,
  interactive = true,
  claims = true,
  clip = true,
  handle = true,
  state = true,
  expand = true,
  focus = true,
  engage = true,
  role = true,
  semantics = true,
  props = true,
  motion = true,
}

local MISSING_VISUAL = 'lunette/missing'

local function record(owner: plugin.Owner, registration: uiHost.KindRegistration): records.Kind
  return {
    name = registration.name,
    owner = owner,
    registration = registration,
    composite = registration.expand ~= nil,
    portal = false,
    outlet = false,
  }
end

-- Lays an override over the registration beneath it.
local function layer(previous: uiHost.KindRegistration, override: uiHost.KindRegistration): uiHost.KindRegistration
  local merged = table.clone(previous) :: { [string]: any }
  for field, value in override :: any do
    merged[field] = value
  end
  local event, beneath = override.event, previous.event
  if event then
    merged.event = function(node: uiHost.Node, given: uiHost.Event, hostBase: (uiHost.Node, uiHost.Event) -> ()): ()
      event(node, given, function(baseNode: uiHost.Node, baseEvent: uiHost.Event): ()
        if beneath then
          beneath(baseNode, baseEvent, hostBase)
        else
          hostBase(baseNode, baseEvent)
        end
      end)
    end
  end
  local expand, expandBeneath = override.expand, previous.expand
  if expand and expandBeneath then
    merged.expand = function(props: uiHost.Props, children: any, state: any, actions: uiHost.Actions): uiHost.Child
      return expand(props, children, state, actions, expandBeneath)
    end
  end
  return merged :: any
end

-- Rebuilds a kind's stack from its base registration and its live overrides, so each node made after the change
-- uses the newest one.
-- An override whose layered result is not a valid registration, such as one that gives a drawing kind an
-- expansion, is skipped; its owner and the reason are answered so the caller can report them.
export type Skipped = { read owner: plugin.Owner, read message: string }

local function restack(target: Registry, name: string): { Skipped }
  local skipped: { Skipped } = {}
  local stack = target.kinds[name]
  if not stack then
    return skipped
  end
  local rebuilt = { stack[1] }
  local registration = stack[1].registration
  for _, entry in target.overrides[name] or {} do
    local layered = layer(registration, entry.registration)
    local ok, failure = pcall(registry.validate, layered)
    if ok then
      registration = layered
      table.insert(rebuilt, record(entry.owner, registration))
    else
      table.insert(skipped, { owner = entry.owner, message = tostring(failure) })
    end
  end
  table.clear(stack)
  for index, kind in rebuilt do
    stack[index] = kind
  end
  return skipped
end

function registry.new(hostOwner: plugin.Owner): Registry
  local missing: records.Kind = {
    name = 'lunette/missing',
    owner = hostOwner,
    composite = false,
    portal = false,
    outlet = false,
    registration = {
      name = 'lunette/missing',
      layout = {
        kind = 'container',
        style = function(): any
          return { minWidth = 0.02, minHeight = 0.02 }
        end,
      },
      visuals = { MISSING_VISUAL },
    },
  }
  -- A portal takes no space in its panel; its overlay root lays out the portal's children in the overlay panel.
  local portal: records.Kind = {
    name = 'lunette/portal',
    owner = hostOwner,
    composite = false,
    portal = true,
    outlet = false,
    registration = {
      name = 'lunette/portal',
      layout = {
        kind = 'leaf',
        style = function(): any
          return { position = 'absolute', width = 0, height = 0 }
        end,
      },
    },
  }
  local overlayRoot: records.Kind = {
    name = 'lunette/overlay-root',
    owner = hostOwner,
    composite = false,
    portal = false,
    outlet = false,
    registration = {
      name = 'lunette/overlay-root',
      layout = {
        kind = 'container',
        style = function(props: uiHost.Props): any
          return { flexDirection = 'column', alignItems = 'stretch', minWidth = props.minWidth }
        end,
      },
    },
  }
  local kinds: { [string]: { records.Kind } } =
    { ['lunette/portal'] = { portal }, ['lunette/overlay-root'] = { overlayRoot } }
  for _, kind in outlets.kinds(hostOwner) do
    kinds[kind.name] = { kind }
  end
  local visuals: { [string]: { { owner: plugin.Owner, visual: uiHost.Visual } } } = {
    [MISSING_VISUAL] = {
      {
        owner = hostOwner,
        visual = function(node: uiHost.Node, draw: uiHost.Draw): ()
          local colors = node.theme.colors
          draw:box(nil, { fill = colors.sunken, border = 0.001, borderColor = colors.danger })
        end,
      },
    },
  }
  for name, visual in outlets.visuals() do
    visuals[name] = { { owner = hostOwner, visual = visual } }
  end
  return {
    kinds = kinds,
    defaultAppearance = false,
    overrides = {},
    visuals = visuals,
    missing = missing,
  }
end

function registry.validate(registration: uiHost.KindRegistration): ()
  assert(type(registration) == 'table', 'ui: a kind registration is a table')
  for field in registration :: any do
    assert(REGISTRATION_FIELDS[field], `ui: '{tostring(field)}' is not a kind registration field`)
  end
  local name = registration.name
  assert(type(name) == 'string' and name ~= '', 'ui: a kind has a name')
  -- A composite measures nothing of its own: it lays out as a container of what it expands into, and only a
  -- container composite draws, behind its expansion, as a scroll view draws its scrollbar.
  assert(
    not (registration.expand and registration.layout and registration.layout.kind ~= 'container'),
    `ui: the composite kind {name} expands into elements instead of measuring`
  )
  assert(
    not (registration.expand and registration.visuals and not registration.layout),
    `ui: the composite kind {name} draws only with a container layout`
  )
  if registration.layout then
    local kind = registration.layout.kind
    assert(
      kind == 'container' or kind == 'text' or kind == 'leaf',
      `ui: {name}: '{tostring(kind)}' is not a layout kind`
    )
  end
end

-- Adds a kind for the owner's lifetime. The returned function removes it; the overrides waiting for the kind are
-- applied, and any that cannot be are answered.
function registry.addKind(
  target: Registry,
  owner: plugin.Owner,
  registration: uiHost.KindRegistration
): (() -> (), { Skipped })
  registry.validate(registration)
  local name = registration.name
  assert(target.kinds[name] == nil, `ui: the kind {name} is already registered`)
  local kind = record(owner, registration)
  local stack = { kind }
  target.kinds[name] = stack
  -- Overrides outlive a base that unloads, and stack again on a base registered under the same name.
  local skipped = restack(target, name)
  return function(): ()
    if target.kinds[name] == stack then
      target.kinds[name] = nil
    end
  end, skipped
end

-- Stacks an override on a registered kind for the owner's lifetime. Fields the override omits keep the previous
-- registration's, and its `event` and `expand` reach the previous ones as `base`. The returned function removes it
-- and rebuilds the overrides above it on the registrations that remain.
function registry.overrideKind(
  target: Registry,
  owner: plugin.Owner,
  name: string,
  registration: uiHost.KindRegistration
): () -> ()
  registry.validate(registration)
  assert(registration.name == name, `ui: an override of {name} keeps the kind's name`)
  -- An override can arrive before the kind it replaces, and applies once the kind is registered.
  local stack = target.kinds[name]
  if stack then
    registry.validate(layer(stack[#stack].registration, registration))
  end
  local entry = { owner = owner, registration = registration }
  local overrides = target.overrides[name] or {}
  target.overrides[name] = overrides
  table.insert(overrides, entry)
  restack(target, name)
  return function(): ()
    local list = target.overrides[name]
    local index = list and table.find(list, entry)
    if list and index then
      table.remove(list, index)
      restack(target, name)
    end
  end
end

-- Kinds and visuals that overrides replace, with the owners of each override, for inspection.
function registry.overridden(target: Registry): { Override }
  local list: { Override } = {}
  local function add(entry: Override): ()
    list[#list + 1] = entry
  end
  for name, overrides in target.overrides do
    for _, entry in overrides do
      add { name = name, owner = entry.owner, kind = 'kind' }
    end
  end
  for name, stack in target.visuals do
    for index = 2, #stack do
      add { name = name, owner = stack[index].owner, kind = 'visual' }
    end
  end
  return list
end

function registry.kind(target: Registry, name: string): records.Kind
  local stack = target.kinds[name]
  if not stack then
    return target.missing
  end
  return if target.defaultAppearance then stack[1] else stack[#stack]
end

function registry.addVisual(target: Registry, owner: plugin.Owner, name: string, visual: uiHost.Visual): () -> ()
  assert(type(name) == 'string' and name ~= '', 'ui: a visual has a name')
  assert(type(visual) == 'function', `ui: the visual {name} is a function`)
  local stack = target.visuals[name]
  if not stack then
    stack = {}
    target.visuals[name] = stack
  end
  local entry = { owner = owner, visual = visual }
  table.insert(stack, entry)
  return function(): ()
    local current = target.visuals[name]
    if current then
      local index = table.find(current, entry)
      if index then
        table.remove(current, index)
      end
    end
  end
end

function registry.visuals(target: Registry, name: string): { uiHost.Visual }
  local stack = target.visuals[name]
  local list: { uiHost.Visual } = {}
  if not stack then
    return list
  end
  if target.defaultAppearance then
    -- The base visual is the one an owner of base kind registrations gave, wherever it sits in the stack, so a
    -- restyle that registered first does not become the default after the standard kinds reload.
    local bases: { [plugin.Owner]: boolean } = {}
    for _, kinds in target.kinds do
      bases[kinds[1].owner] = true
    end
    for _, entry in stack do
      if bases[entry.owner] then
        return { entry.visual }
      end
    end
    return { stack[1].visual }
  end
  for index, entry in stack do
    list[index] = entry.visual
  end
  return list
end

return registry

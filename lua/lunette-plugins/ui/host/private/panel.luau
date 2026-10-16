-- A panel: a native layout tree, a root mount point, a surface for pointing, and the commit that brings the three
-- together each frame.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local uiHost = require '@lunette-contracts/ui-host'
local vocabulary = require '@lunette-contracts/vocabulary'
local records = require './records'
local tree = require './tree'
local layout = require './layout'
local input = require './input'
local shape = require './shape'
local placements = require './placements'

local panel = {}

export type Provider = {
  read env: records.Environment,
  read router: input.Router,
  read offer: (records.Panel, vocabulary.Surface) -> (),
  read release: (records.Panel) -> (),
  -- The record behind a panel handle this host made.
  read resolve: (uiHost.Panel) -> records.Panel,
  -- The surface a live panel offers.
  read surfaceOf: (records.Panel) -> vocabulary.Surface?,
}

local function positive(value: number?, label: string): ()
  if value ~= nil then
    assert(type(value) == 'number' and value > 0 and value < math.huge, `ui: the panel {label} is a positive length`)
  end
end

-- Builds the panel record, its handle, and its surface.
function panel.new(
  provider: Provider,
  owner: plugin.Owner,
  options: uiHost.PanelOptions
): (records.Panel, uiHost.Panel, vocabulary.Surface)
  assert(type(options) == 'table', 'ui: panel options are a table')
  assert(type(options.name) == 'string' and options.name ~= '', 'ui: a panel has a name')
  positive(options.width, 'width')
  positive(options.height, 'height')
  local sizing = options.size or (if options.width and options.height then 'fixed' else 'content')
  assert(sizing == 'fixed' or sizing == 'content', `ui: '{tostring(sizing)}' is not a panel size`)
  if sizing == 'fixed' then
    assert(options.width and options.height, 'ui: a fixed panel has a width and a height')
  end
  local record = panel.record(options.name, owner, sizing, options.width, options.height, options.pose)
  local presentation = options.presentation or 'world'
  assert(
    presentation == 'world' or presentation == 'follow' or presentation == 'dialog' or presentation == 'attach',
    `ui: '{tostring(presentation)}' is not a presentation`
  )
  record.presentation = presentation
  record.visible = options.visible ~= false
  local curve = options.curve or 0
  assert(type(curve) == 'number' and curve >= 0 and curve < 10, 'ui: a curve is from 0 to 10 per metre')
  record.curve = curve
  record.grabbable = (presentation == 'world' or presentation == 'attach') and options.grabbable ~= false
  if presentation == 'attach' then
    local target = options.target
    assert(target ~= nil and target.width and target.height, 'ui: an attached panel names a target surface')
    assert(options.height, 'ui: an attached panel has a height')
    record.target = target
    record.gap = options.gap or 0
    record.sizing = 'fixed'
    record.minWidth = target.width or 0
    record.width = target.width or 0
  end
  -- Panels that the host shows and hides fade in.
  if presentation == 'dialog' or presentation == 'follow' then
    record.fade = { value = 0, target = 1, velocity = 0 }
  end
  if presentation == 'dialog' then
    local modality = options.modality or 'panel'
    assert(modality == 'panel' or modality == 'session', `ui: '{tostring(modality)}' is not a modality`)
    record.modality = modality
    record.parent = if options.parent then provider.resolve(options.parent) else nil
  end
  local env = provider.env

  local mount: uiHost.Mount = {
    bind = function(_self: uiHost.Mount, adapter: uiHost.Adapter): ()
      assert(
        type(adapter) == 'table' and type(adapter.render) == 'function',
        'ui: a mount adapter has a render function'
      )
      record.mount.adapter = adapter
      record.mount.scheduled = true
    end,
    schedule = function(_self: uiHost.Mount): ()
      record.mount.scheduled = true
    end,
    submit = function(_self: uiHost.Mount, element: uiHost.Element?): ()
      assert(record.mount.rendering, 'ui: a mount point accepts elements only while the host renders it')
      record.mount.element = element
      tree.submit(record, env, element)
    end,
    committed = function(_self: uiHost.Mount): boolean
      return record.mount.committed
    end,
  }

  local handle: uiHost.Panel
  local surface = panel.surface(provider, record, function(pose: Mat4): ()
    handle:setPose(pose)
  end)
  handle = {
    name = record.name,
    dead = false,
    root = mount,
    pose = function(_self: uiHost.Panel): Mat4
      return lovr.math.mat4(record.pose)
    end,
    setPose = function(_self: uiHost.Panel, pose: Mat4): ()
      if not record.dead then
        record.pose:set(pose)
        record.revision += 1
      end
    end,
    size = function(_self: uiHost.Panel): (number, number)
      return record.width, record.height
    end,
    setSize = function(_self: uiHost.Panel, width: number?, height: number?): ()
      positive(width, 'width')
      positive(height, 'height')
      if record.sizing == 'fixed' then
        record.width, record.height = width or record.width, height or record.height
      else
        record.maxWidth, record.maxHeight = width, height
        -- The host root's maximum is part of its style, so it is restyled at the next commit.
        record.rootSize = nil
        local change: lunette.LayoutChange = { op = 'style', id = layout.ROOT, style = layout.rootStyle(record) }
        table.insert(record.changes, change)
      end
    end,
    setCurve = function(_self: uiHost.Panel, curve: number): ()
      assert(type(curve) == 'number' and curve >= 0 and curve < 10, 'ui: a curve is from 0 to 10 per metre')
      record.curve = curve
    end,
    setGap = function(_self: uiHost.Panel, gap: number): ()
      assert(type(gap) == 'number' and gap >= 0 and gap < math.huge, 'ui: a gap is a non-negative length')
      record.gap = gap
    end,
    setVisible = function(_self: uiHost.Panel, visible: boolean): ()
      record.visible = visible == true
      -- A hidden panel gives up its focus, so the keyboard does not stay up for a field nobody can see.
      if not record.visible and record.focused then
        env.blurNode(record.focused)
      end
      record.sync()
    end,
    destroy = function(_self: uiHost.Panel): ()
      panel.destroy(provider, record);
      (handle :: any).dead = true
      record.sync()
    end,
    find = function(_self: uiHost.Panel, path: string): uiHost.Node?
      return panel.find(record, path)
    end,
  }
  provider.offer(record, surface)
  return record, handle, surface
end

-- The surface through which the interaction service points at a panel. It keeps the record's sync function, which
-- publishes the size and liveness to the surface after each commit.
function panel.surface(provider: Provider, record: records.Panel, setPose: ((Mat4) -> ())?): vocabulary.Surface
  local env = provider.env
  local surface: vocabulary.Surface = {
    kind = nil,
    dead = false,
    grabbable = record.grabbable,
    pose = record.pose,
    width = record.width,
    height = record.height,
    raycast = function(
      _self: vocabulary.Surface,
      origin: vector,
      direction: vector,
      backFace: boolean?
    ): (number?, number?, number?)
      if record.dead or record.closing or not record.visible or record.width <= 0 or record.height <= 0 then
        return nil, nil, nil
      end
      local localOrigin, localDirection = shape.localRay(record, origin, direction)
      -- A flat panel answers rays from behind only when asked, as window panels do.
      if record.curve <= 0 and localDirection.z >= 0 and not backFace then
        return nil, nil, nil
      end
      return shape.ray(record, localOrigin, localDirection, true)
    end,
    project = function(_self: vocabulary.Surface, origin: vector, direction: vector): (number?, number?, number?)
      if record.width <= 0 or record.height <= 0 then
        return nil, nil, nil
      end
      local localOrigin, localDirection = shape.localRay(record, origin, direction)
      return shape.ray(record, localOrigin, localDirection, false)
    end,
    onPointer = function(self: vocabulary.Surface, event: vocabulary.PointerEvent): ()
      if record.dead then
        return
      end
      -- The trigger grabs an attached panel's target from empty space, and presses nodes elsewhere, so a titlebar
      -- moves its window and still takes clicks on its buttons. The interaction service reads the field when the
      -- press arrives, after the moves that led to it.
      if record.target and event.x and event.y then
        (self :: any).triggerGrabbable = input.target(record, env, event.x, event.y) == nil
      end
      input.pointer(provider.router, record, env, event)
    end,
    setPose = if setPose
      then function(_self: vocabulary.Surface, pose: Mat4): ()
        setPose(pose)
      end
      else nil,
    -- Grabbing an attached panel grabs the surface it is attached to.
    grabTarget = if record.target
      then function(_self: vocabulary.Surface): vocabulary.Surface?
        local target = record.target
        return if target and not target.dead then target else nil
      end
      else nil,
  }
  local fields = surface :: any
  record.sync = function(): ()
    fields.width, fields.height = record.width, record.height
    fields.dead = record.dead or record.closing or not record.visible
  end
  return surface
end

-- A panel record with no content. A content-sized panel takes the width and height as its maximum.
function panel.record(
  name: string,
  owner: plugin.Owner,
  sizing: 'fixed' | 'content',
  width: number?,
  height: number?,
  pose: Mat4?
): records.Panel
  local record: records.Panel = {
    name = name,
    owner = owner,
    tree = nil :: any,
    root = nil,
    rootChild = nil,
    mount = { adapter = nil, scheduled = false, committed = false, rendering = false, submitted = false, element = nil },
    nodes = {},
    nextId = layout.ROOT + 1,
    changes = {},
    dirty = false,
    sizing = sizing,
    maxWidth = if sizing == 'content' then width else nil,
    maxHeight = if sizing == 'content' then height else nil,
    width = width or 0,
    height = height or 0,
    pose = lovr.math.newMat4(pose or lovr.math.mat4()),
    visible = true,
    dead = false,
    grabbable = false,
    revision = 0,
    sync = function(): () end,
    overlay = nil,
    focused = nil,
    session = nil,
    fade = nil,
    ghosts = {},
    closing = false,
    presentation = 'world',
    curve = 0,
    target = nil,
    gap = 0,
    rootSize = nil,
    parent = nil,
    modality = nil,
    followTarget = nil,
    placements = {},
  }
  record.tree = layout.newTree(record)
  return record
end

-- Outlet contributions that place outlets of their own nest; a commit renders this many levels of them, and a deeper
-- level renders in the next commit.
local CONTRIBUTION_PASSES = 8

-- Renders the mount point when it has scheduled work, re-expands and restyles dirty nodes, and recomputes layout.
-- The contributions to the panel's outlets render after the root, so they see the props it placed them with.
function panel.commit(provider: Provider, record: records.Panel): ()
  if record.dead then
    return
  end
  local env = provider.env
  local mount = record.mount
  if mount.scheduled and mount.adapter then
    mount.scheduled = false
    mount.rendering = true
    local adapter = mount.adapter
    env.protect(`ui: panel '{record.name}' render`, function(): ()
      adapter.render()
    end)
    mount.rendering = false
  end
  for _ = 1, CONTRIBUTION_PASSES do
    placements.render(env, record)
    if record.dirty then
      record.dirty = false
      tree.refresh(record, env)
    end
    if not placements.pending(record) then
      break
    end
  end
  placements.committed(record)
  layout.commit(record, env)
  -- Placement here, not only at draw, lets hit testing in the same frame see this commit's layout.
  layout.place(record)
  mount.committed = mount.adapter ~= nil
  record.sync()
end

function panel.destroy(provider: Provider, record: records.Panel): ()
  if record.dead then
    return
  end
  local mount = record.mount
  if mount.adapter and mount.adapter.unmount then
    local unmount = mount.adapter.unmount
    provider.env.protect(`ui: panel '{record.name}' unmount`, function(): ()
      unmount()
    end)
  end
  mount.rendering = true
  tree.submit(record, provider.env, nil)
  mount.rendering = false
  record.dead = true
  provider.release(record)
end

-- Finds a node by its key path from the content root, such as 'controls/enabled'. Unkeyed nodes are addressed by
-- their slot.
function panel.find(record: records.Panel, path: string): uiHost.Node?
  local node = record.root
  if not node then
    return nil
  end
  -- A portal's children are its overlay's root, which is searched through like an unkeyed wrapper.
  local function childrenOf(parent: records.Node): { records.Node }
    local opened = parent.overlay
    if opened and opened.root then
      return { opened.root }
    end
    return parent.children
  end
  local function child(parent: records.Node, slot: string): records.Node?
    for _, candidate in childrenOf(parent) do
      if candidate.slot == slot or candidate.key == slot then
        return candidate
      end
    end
    -- Composite expansions and unkeyed wrappers are searched through, so a path names only keyed nodes.
    for _, candidate in childrenOf(parent) do
      if candidate.key == nil then
        local found = child(candidate, slot)
        if found then
          return found
        end
      end
    end
    return nil
  end
  for segment in string.gmatch(path, '[^/]+') do
    local found = child(node :: records.Node, segment)
    if not found then
      return nil
    end
    node = found
  end
  return node and node.handle
end

return panel

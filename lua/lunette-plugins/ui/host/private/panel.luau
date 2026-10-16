-- A panel: a native layout tree, a root mount point, a surface for pointing, and the commit that brings the three
-- together each frame.

local plugin = require '@lunette-plugin'
local uiHost = require '@lunette-contracts/ui-host'
local vocabulary = require '@lunette-contracts/vocabulary'
local quad = require '@lunette-contracts/quad'
local records = require './records'
local tree = require './tree'
local layout = require './layout'
local input = require './input'

local panel = {}

export type Provider = {
  read env: records.Environment,
  read router: input.Router,
  read offer: (records.Panel, vocabulary.Surface) -> (),
  read release: (records.Panel) -> (),
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
  local record: records.Panel = {
    name = options.name,
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
    maxWidth = if sizing == 'content' then options.width else nil,
    maxHeight = if sizing == 'content' then options.height else nil,
    width = options.width or 0,
    height = options.height or 0,
    pose = lovr.math.newMat4(options.pose or lovr.math.mat4()),
    visible = true,
    dead = false,
    grabbable = options.grabbable ~= false,
    revision = 0,
    sync = function(): () end,
  }
  record.tree = layout.newTree(record)
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

  local surface: vocabulary.Surface
  local handle: uiHost.Panel
  local surfaceFields: any
  local function sync(): ()
    surfaceFields.width, surfaceFields.height = record.width, record.height
    surfaceFields.dead = record.dead or not record.visible
  end
  surface = {
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
      if record.dead or not record.visible or record.width <= 0 or record.height <= 0 then
        return nil, nil, nil
      end
      return quad.hit({
        pose = record.pose,
        width = record.width,
        height = record.height,
        pixelWidth = record.width,
        pixelHeight = record.height,
        backFace = backFace,
      }, origin, direction)
    end,
    project = function(_self: vocabulary.Surface, origin: vector, direction: vector): (number?, number?, number?)
      if record.width <= 0 or record.height <= 0 then
        return nil, nil, nil
      end
      return quad.project({
        pose = record.pose,
        width = record.width,
        height = record.height,
        pixelWidth = record.width,
        pixelHeight = record.height,
      }, origin, direction)
    end,
    onPointer = function(_self: vocabulary.Surface, event: vocabulary.PointerEvent): ()
      if not record.dead then
        input.pointer(provider.router, record, env, event)
      end
    end,
    setPose = function(_self: vocabulary.Surface, pose: Mat4): ()
      handle:setPose(pose)
    end,
  }
  surfaceFields = surface :: any

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
    setVisible = function(_self: uiHost.Panel, visible: boolean): ()
      record.visible = visible == true
      sync()
    end,
    destroy = function(_self: uiHost.Panel): ()
      panel.destroy(provider, record);
      (handle :: any).dead = true
      sync()
    end,
    find = function(_self: uiHost.Panel, path: string): uiHost.Node?
      return panel.find(record, path)
    end,
  }
  record.sync = sync
  provider.offer(record, surface)
  return record, handle, surface
end

-- Renders the mount point when it has scheduled work, re-expands and restyles dirty nodes, and recomputes layout.
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
  if record.dirty then
    record.dirty = false
    tree.refresh(record, env)
  end
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
  local function child(parent: records.Node, slot: string): records.Node?
    for _, candidate in parent.children do
      if candidate.slot == slot or candidate.key == slot then
        return candidate
      end
    end
    -- Composite expansions and unkeyed wrappers are searched through, so a path names only keyed nodes.
    for _, candidate in parent.children do
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

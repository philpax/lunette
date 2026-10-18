-- Records the panels that the UI host creates in a session, so a test can address another plugin's nodes by key path
-- and click them through the fake XR boundary. The recorder replaces the `ui-host` entry with a definition that
-- publishes the real host service, wrapped so that `newPanel` remembers each panel it returns.

local adapter = require '@lunette-plugin/adapter'
local uiHost = require '@lunette-contracts/ui-host'
local hostPlugin = require '@lunette-plugins/ui/host'
local vrUi = require '@testing/vr-ui'

local uiPanels = {}

-- The thumbstick deflection that reveal scrolls with.
local SCROLL = 0.6

export type Recorder = {
  -- The replacement for the host's definition, under the entry id `ui-host`.
  read definition: adapter.Definition<any>,
  read entry: { read id: string, read definition: adapter.Definition<any> },
  -- The newest live panel with the name.
  read panel: (Recorder, string) -> uiHost.Panel?,
  -- The live node at the key path in the named panel.
  read node: (Recorder, string, string) -> uiHost.Node?,
  -- Presses and releases the trigger with the ray on the centre of the node, then commits the result.
  read click: (Recorder, vrUi.Fixture, string, string, vrUi.Hand?) -> (),
}

local function wrap(service: uiHost.Service, panels: { uiHost.Panel }): uiHost.Service
  local wrapped: { [string]: any } = {}
  for name, method in service :: any do
    if type(method) == 'function' then
      wrapped[name] = function(_self: any, ...: any): ...any
        return method(service, ...)
      end
    else
      wrapped[name] = method
    end
  end
  wrapped.newPanel = function(_self: any, owner: uiHost.Owner, options: uiHost.PanelOptions): uiHost.Panel
    local panel = service:newPanel(owner, options)
    table.insert(panels, panel)
    return panel
  end
  return table.freeze(wrapped) :: any
end

-- A geometry centred on the node, facing out of its panel, for the fixture's aim.
local function geometry(node: uiHost.Node): vrUi.Geometry
  return { pose = node:pose(), width = 1, height = 1, logicalWidth = 1, logicalHeight = 1, visible = true }
end

function uiPanels.new(): Recorder
  local panels: { uiHost.Panel } = {}
  local host = hostPlugin.definition
  local definition = adapter.define({
    name = host.name,
    requires = host.requires,
    provides = host.provides,
    init = function(context: adapter.Context, config: any, publish: adapter.Publisher): ()
      local publisher: adapter.Publisher = {
        provide = function<T>(_self: adapter.Publisher, capability: adapter.Capability<T>, value: T): ()
          if (capability :: any) == uiHost.capability then
            publish:provide(capability, wrap(value :: any, panels) :: any)
          else
            publish:provide(capability, value)
          end
        end,
      }
      local init = host.init :: any
      init(context, config, publisher)
    end,
  }, if host.resolve then { schema = host.schema, resolve = host.resolve } else nil)

  local recorder = {} :: Recorder
  local function find(name: string): uiHost.Panel?
    for index = #panels, 1, -1 do
      local panel = panels[index]
      if panel.name == name and not panel.dead then
        return panel
      end
    end
    return nil
  end
  local function node(name: string, path: string): uiHost.Node?
    local panel = find(name)
    return if panel then panel:find(path) else nil
  end
  local fields = recorder :: any
  fields.definition = definition
  fields.entry = { id = 'ui-host', definition = definition }
  fields.panel = function(_self: Recorder, name: string): uiHost.Panel?
    return find(name)
  end
  fields.node = function(_self: Recorder, name: string, path: string): uiHost.Node?
    return node(name, path)
  end
  -- Scrolls the nearest scrolling ancestor with the thumbstick until the node lies inside it.
  local function reveal(fixture: vrUi.Fixture, name: string, path: string, hand: vrUi.Hand): ()
    local target = node(name, path)
    assert(target and not target.dead, `ui-panels: no node at {name}/{path}`)
    local box = target.parent
    while box do
      local _, contentHeight = box:contentSize()
      if contentHeight > box.bounds.height + 1e-6 then
        break
      end
      box = box.parent
    end
    if not box then
      return
    end
    local scroller: uiHost.Node = box
    -- The distance from the node to the inside of the box: positive below it and negative above it.
    local function outside(): number
      local current = node(name, path)
      assert(current, `ui-panels: {name}/{path} disappeared while scrolling`)
      local inner, outer = current:panelBounds(), scroller:panelBounds()
      if inner.y + inner.height > outer.y + outer.height + 1e-6 then
        return inner.y + inner.height - outer.y - outer.height
      elseif inner.y < outer.y - 1e-6 then
        return inner.y - outer.y
      end
      return 0
    end
    local direction = 1
    local previous = outside()
    for _ = 1, 400 do
      if previous == 0 then
        break
      end
      fixture:aim(geometry(scroller), 0.5, 0.5, hand)
      -- A light deflection scrolls a few centimetres a frame, so the node is not carried past the box.
      fixture:axis(hand, 0, (if previous > 0 then -direction else direction) * SCROLL)
      fixture:step()
      fixture:axis(hand, 0, 0)
      -- A scroll changes node state while pointing, and the next commit places the nodes where it moved them.
      fixture:step()
      local distance = outside()
      if math.abs(distance) >= math.abs(previous) then
        direction = -direction
      end
      previous = distance
    end
    assert(previous == 0, `ui-panels: scrolling does not reveal {name}/{path}`)
  end
  -- Aims again before the press because a panel can follow a hand or another surface.
  fields.click = function(_self: Recorder, fixture: vrUi.Fixture, name: string, path: string, hand: vrUi.Hand?): ()
    local chosen: vrUi.Hand = hand or 'right'
    -- A frame first commits content that changed since the last one, as a panel shown on a tracked wrist.
    fixture:button(chosen, 'trigger', false)
    fixture:step()
    reveal(fixture, name, path, chosen)
    local function aim(): ()
      local target = node(name, path)
      assert(target and not target.dead, `ui-panels: no node at {name}/{path}`)
      fixture:aim(geometry(target), 0.5, 0.5, chosen)
    end
    fixture:button(chosen, 'trigger', false)
    aim()
    fixture:step()
    aim()
    fixture:step()
    fixture:button(chosen, 'trigger', true)
    fixture:step()
    fixture:button(chosen, 'trigger', false)
    fixture:step()
    -- Activation arrives while pointing, after the frame's commit, so the next frame commits what it changed.
    fixture:step()
  end
  return table.freeze(recorder)
end

return uiPanels

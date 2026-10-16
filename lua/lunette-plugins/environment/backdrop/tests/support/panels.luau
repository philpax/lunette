-- Records the panels that the React-like library mounts, so tests can address the control panel's nodes by key.
-- The host's inspection reports panels but not their nodes, and services are read-only, so the recorder wraps the
-- library's mount function. Source reload loads a fresh library, so a reloaded configuration records again.
local uiHost = require '@lunette-contracts/ui-host'
local ui = require '@lunette-plugins/ui/react'
local hostFixture = require '@testing/ui-host'
local vrUi = require '@testing/vr-ui'

local panels = {}

export type Recorder = {
  -- The latest mounted panel with each name.
  read panels: { [string]: uiHost.Panel },
}

local recorders: { Recorder } = {}
local wrapped: { [any]: boolean } = setmetatable({}, { __mode = 'k' })

-- Starts recording the panels mounted from now on.
function panels.recorder(): Recorder
  local recorder: Recorder = { panels = {} }
  table.insert(recorders, recorder)
  local library: any = ui
  if not wrapped[library] then
    wrapped[library] = true
    local mount = library.mount
    library.mount = function(panel: uiHost.Panel, element: any, options: any): any
      for _, each in recorders do
        each.panels[panel.name] = panel
      end
      return mount(panel, element, options)
    end
  end
  return recorder
end

function panels.panel(recorder: Recorder, name: string): uiHost.Panel
  local panel = assert(recorder.panels[name], `no panel named {name}`)
  assert(not panel.dead, `the panel {name} is dead`)
  return panel
end

function panels.node(recorder: Recorder, name: string, path: string): uiHost.Node
  return assert(panels.panel(recorder, name):find(path), `no node at {name}:{path}`)
end

-- Whether the host reports a live, visible panel with the name.
function panels.visible(service: uiHost.Service, name: string): boolean
  for _, registration in service:inspect().registrations do
    if registration.live and registration.kind == 'panel' and registration.name == name then
      return registration.details.visible == true
    end
  end
  return false
end

-- Aims at the centre of the node at the key path and presses and releases the trigger across frames. It aims again
-- before each frame, because a content-sized panel can move its nodes when its content changes.
function panels.click(running: vrUi.Fixture, recorder: Recorder, name: string, path: string): ()
  local function aim(): ()
    running:aim(hostFixture.nodeGeometry(panels.node(recorder, name, path)), 0.5, 0.5)
  end
  running:button('right', 'trigger', false)
  aim()
  running:step(0)
  aim()
  running:button('right', 'trigger', true)
  running:step(0)
  running:button('right', 'trigger', false)
  running:step(0)
end

-- Drags a slider's thumb from its value to near `value`, so the release snaps to a nearby detent. A press without
-- movement activates the track, which does not move the value.
function panels.slide(running: vrUi.Fixture, recorder: Recorder, name: string, path: string, value: number): ()
  local track = panels.node(recorder, name, path .. '/track')
  local width = track.bounds.width
  local thumb = track.theme.sizes.thumb * 0.7
  local function at(fraction: number): number
    return 0.5 + thumb / 2 + (width - thumb) * fraction - width / 2
  end
  local geometry = hostFixture.nodeGeometry(track)
  local from = track.props.value
  running:button('right', 'trigger', false)
  running:aim(geometry, at(from), 0.5)
  running:step(0)
  running:button('right', 'trigger', true)
  running:step(0)
  for step = 1, 4 do
    running:aim(geometry, at(from + (value - from) * step / 4), 0.5)
    running:step(0)
  end
  running:button('right', 'trigger', false)
  running:step(0)
end

return panels

-- Placement in the shipped composition: the entries need no particular order,
-- a window dropped while the arrangement was unloaded stays where it was
-- dropped, a tag's own layout arranges it, a replaced placement forwards a
-- property of its own, a rule's `where` and `hidden` reach the panel, the
-- adoption filter leaves a window alone, and the arrangement can be saved
-- and restored on demand to a configured file.
local plugin = require '@lunette-plugin'
local desktopRoot = require '@lunette-desktop'
local tagsContract = require '@lunette-contracts/tags'
local layoutsContract = require '@lunette-contracts/layouts'
local arrangementContract = require '@lunette-contracts/arrangement'
local placementModule = require '@lunette-plugins/placement'
local vocabulary = require '@lunette-contracts/vocabulary'

local function position(panel)
  local x, y, z = panel.pose:getPosition()
  return x, y, z
end

local function probe(desktop)
  local found = {}
  desktop.runtime
    :use(
      plugin.define {
        name = 'placement-probe',
        requires = {
          tags = tagsContract.capability,
          layouts = layoutsContract.capability,
          arrangement = arrangementContract.capability,
        },
        init = function(context)
          found.owner = context
          found.tags = context:require(tagsContract.capability)
          found.layouts = context:require(layoutsContract.capability)
          found.arrangement = context:require(arrangementContract.capability)
        end,
      },
      {}
    )
    :enable()
  return found
end

-- The workspace entry last, after adoption has placed a window into the tag
-- it names, and after the saved arrangement restored a mirror into it: the
-- tag is held, not made, so the order does not matter.
do
  events.saved = 'return { version = 1, entries = { { kind = "monitor", key = "fixture-output", slot = 1, '
    .. 'pose = "1 0 0 0 0 1 0 0 0 0 1 0 0 1 -2 1", tags = { "main" } } } }'
  local monitor = newMonitor 'fixture-output'
  events.monitors[monitor.id] = monitor
  local window = newWindow(70)
  events.windows = { window }
  local reordered = {}
  local workspace
  for _, entry in ipairs(desktopRoot.entries()) do
    if entry.id == 'desktop/workspace' then
      workspace = entry
    else
      reordered[#reordered + 1] = entry
    end
  end
  reordered[#reordered + 1] = workspace
  local desktop = require 'fixture/graph' { entries = reordered }
  for id, instance in pairs(desktop.instances) do
    assert(instance:state() == 'active', id .. ': ' .. tostring(instance:diagnostic()))
  end
  local found = probe(desktop)
  local main = assert(found.tags:find 'main')
  assert(main.selected, 'the workspace selects its tag whoever made it')
  assert(main:has(desktop.panels:forSource(window)), 'the window joined the tag before the workspace started')
  desktop.consumers.workspace:disable()
  assert(not main.dead, 'the tag outlives the workspace while placements hold it')
  desktop.consumers.workspace:enable()
  assert(lovr.quit() == false)
  events.saved = nil
  events.windows = {}
  events.monitors = {}
end

-- A window dropped while desktop/arrange is unloaded stays where it was
-- dropped when the arrangement returns: pose memory kept its pose.
do
  local desktop = require 'fixture/graph'()
  local first, second, third = newWindow(1), newWindow(2), newWindow(3)
  events.windows = { first, second, third }
  for _, window in ipairs(events.windows) do
    emit('onWindowOpened', { window = window })
  end
  local dragged = assert(desktop.panels:forSource(first))
  desktop.consumers.arrange:disable()
  dragged:setPose(lovr.math.newMat4():translate(3, 2, -4))
  desktop.drop(dragged)
  assert(first:getProperty(vocabulary.POSE_PROPERTY), 'pose memory kept the dropped pose')
  desktop.consumers.arrange:enable()
  local x, y, z = position(dragged)
  assert(x == 3 and y == 2 and z == -4, 'recovery leaves the dropped window: ' .. x .. ' ' .. y .. ' ' .. z)
  second.dead = true
  events.windows = { first, third }
  emit('onWindowClosed', { window = second })
  lovr.update(0.016)
  x, y, z = position(dragged)
  assert(x == 3 and y == 2 and z == -4, 'a later arrangement leaves it too')
  assert(lovr.quit() == false)
end

-- A tag's own layout arranges it, and each tag is arranged apart.
do
  events.saved = nil
  events.windows = {}
  local desktop = require 'fixture/graph' {
    patches = {
      {
        id = 'desktop/rules',
        config = { rules = { { match = { appId = 'mail' }, properties = { tags = { 'mail' } } } } },
      },
    },
  }
  local found = probe(desktop)
  local arranged = {}
  found.layouts:register(found.owner, {
    name = 'line',
    apply = function(panels)
      arranged[#arranged + 1] = #panels
      for index, panel in ipairs(panels) do
        panel:setPose(lovr.math.newMat4():translate(index * 10, 0, 0))
      end
    end,
  })
  local main = assert(found.tags:find 'main')
  local terminal, other, mail = newWindow(80), newWindow(81), newWindow(82, 'mail')
  events.windows = { terminal, other, mail }
  for _, window in ipairs(events.windows) do
    emit('onWindowOpened', { window = window })
  end
  local mailTag = assert(found.tags:find 'mail')
  assert(not main:has(desktop.panels:forSource(mail)), 'a rule names the tags a window joins')
  table.clear(arranged)
  main:setLayout(found.owner, { layout = 'line' })
  assert(
    #arranged == 1 and arranged[1] == 2,
    'changing a tag layout arranges it with its own: ' .. table.concat(arranged, ',')
  )
  assert(position(desktop.panels:forSource(other)) == 20, 'the tag layout posed its members')
  local mx, my = position(desktop.panels:forSource(mail))
  assert(mx == 0 and my == 1.5, 'another tag keeps the configured layout')
  mailTag:setLayout(found.owner, { layout = 'line' })
  assert(position(desktop.panels:forSource(mail)) == 10, 'each tag is arranged apart')
  assert(lovr.quit() == false)
end

-- A window in several tags is arranged by the first selected tag that holds
-- it, and a layout's options are keyed by its name, whichever tag uses it.
do
  events.saved = nil
  events.windows = {}
  local desktop = require 'fixture/graph' {
    patches = {
      {
        id = 'desktop/rules',
        config = { rules = { { match = { appId = 'mail' }, properties = { tags = { 'main', 'mail' } } } } },
      },
      { id = 'desktop/arrange', config = { options = { line = { spacing = 10 } } } },
    },
  }
  local found = probe(desktop)
  for _, registration in ipairs { { name = 'line', sign = 1 }, { name = 'reverse', sign = -1 } } do
    found.layouts:register(found.owner, {
      name = registration.name,
      apply = function(panels, options)
        local spacing = if options then options.spacing else 1
        for index, panel in ipairs(panels) do
          panel:setPose(lovr.math.newMat4():translate(registration.sign * index * spacing, 0, 0))
        end
      end,
    })
  end
  local main = assert(found.tags:find 'main')
  main:setLayout(found.owner, { layout = 'line' })
  local terminal, mail = newWindow(83), newWindow(84, 'mail')
  events.windows = { terminal, mail }
  for _, window in ipairs(events.windows) do
    emit('onWindowOpened', { window = window })
  end
  local mailTag = assert(found.tags:find 'mail')
  local mailPanel = assert(desktop.panels:forSource(mail))
  assert(main:has(mailPanel) and mailTag:has(mailPanel), 'the rule puts the window in both tags')
  assert(main.selected and not mailTag.selected)
  assert(position(mailPanel) == 20, 'the selected tag arranges it, with its layout options')
  mailTag:setLayout(found.owner, { layout = 'reverse' })
  assert(position(mailPanel) == 20, 'an unselected tag does not take it from a selected one')
  mailTag:setSelected(found.owner, { selected = true })
  main:setSelected(found.owner, { selected = false })
  assert(position(mailPanel) == -1, 'selecting the other tag arranges it there, with no options for its layout')
  main:setSelected(found.owner, { selected = true })
  assert(position(mailPanel) == 20, 'the first selected tag in order wins')
  assert(lovr.quit() == false)
end

-- A replaced placement forwards a property of its own, and a rule's where
-- and hidden reach the panel; a filtered window is not adopted.
do
  events.saved = nil
  events.windows = {}
  local bending = placementModule.define {
    name = 'bending-placement',
    panelOptions = function(properties, window, base)
      local options = base(properties, window)
      local bend = properties.bend
      if type(bend) == 'number' then
        options.curve = bend
      end
      return options
    end,
  }
  local desktop = require 'fixture/graph' {
    patches = {
      { id = 'placement', definition = bending },
      {
        id = 'desktop/rules',
        config = {
          rules = {
            {
              match = {
                where = function(window)
                  return window.id == 90
                end,
              },
              properties = { bend = 0.5 },
            },
            { match = { appId = 'tray' }, properties = { hidden = true } },
          },
        },
      },
      {
        id = 'desktop/adoption',
        config = {
          filter = function(window)
            return window.appId ~= 'launcher'
          end,
        },
      },
    },
  }
  local bent, tray, launcher = newWindow(90), newWindow(91, 'tray'), newWindow(92, 'launcher')
  events.windows = { bent, tray, launcher }
  for _, window in ipairs(events.windows) do
    emit('onWindowOpened', { window = window })
  end
  assert(desktop.panels:forSource(bent).curve == 0.5, 'the replaced placement forwards its property')
  assert(desktop.panels:forSource(tray).hidden, 'a rule hides a window')
  assert(desktop.panels:forSource(launcher) == nil, 'the filter leaves a window alone')
  assert(lovr.quit() == false)
end

-- The arrangement is saved and restored on demand, in the configured file.
do
  events.saved = nil
  events.windows = {}
  local write = lovr.filesystem.write
  local read = lovr.filesystem.read
  local names = {}
  lovr.filesystem.write = function(name, text)
    names[#names + 1] = name
    return write(name, text)
  end
  lovr.filesystem.read = function(name)
    names[#names + 1] = name
    return read(name)
  end
  local desktop =
    require 'fixture/graph' { patches = { { id = 'desktop/persistence', config = { file = 'profile.state' } } } }
  local found = probe(desktop)
  local window = newWindow(100)
  events.windows = { window }
  emit('onWindowOpened', { window = window })
  local panel = desktop.panels:forSource(window)
  panel:setPose(lovr.math.newMat4():translate(5, 1, -5))
  local writes = events.writes
  assert(found.arrangement:save() == true and events.writes == writes + 1, 'save writes the arrangement')
  panel:setPose(lovr.math.newMat4():translate(0, 0, 0))
  assert(found.arrangement:restore() >= 1, 'restore places the live panels')
  local x, _, z = position(panel)
  assert(x == 5 and z == -5, 'restore puts the panel where it was saved')
  assert(not pcall(function()
    found.arrangement:save { forced = true }
  end), 'save rejects a field it does not take')
  for _, name in ipairs(names) do
    assert(name == 'profile.state', 'every read and write names the configured file: ' .. tostring(name))
  end
  assert(#names >= 2)
  lovr.filesystem.write, lovr.filesystem.read = write, read
  assert(lovr.quit() == false)
end

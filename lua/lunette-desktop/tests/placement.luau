-- Placement supports entry reordering, per-tag layouts, first-selected-tag precedence, replacement providers, rule predicates, and adoption filters.
local testing = require '@testing'
local expect = testing.expect
local desktop = require '@lunette-desktop'
local placementModule = require '@lunette-plugins/placement'
local panelsContract = require '@lunette-contracts/panels'
local tagsContract = require '@lunette-contracts/tags'
local layoutsContract = require '@lunette-contracts/layouts'

local test = testing.suite()

local function start(entries, fake)
  local session = testing.boot(entries, { native = fake })
  local env = { session = session, native = session.native, events = session.native.events }
  env.panels = session:observe(panelsContract.capability)
  local tags = session:observe(tagsContract.capability)
  env.tags, env.owner = tags.service, tags.context
  env.layouts = session:observe(layoutsContract.capability)
  return env
end

local function open(env, windows)
  env.events.windows = windows
  for _, window in ipairs(windows) do
    env.native.emit('onWindowOpened', { window = window })
  end
end

local function x(panel)
  return (panel.pose:getPosition())
end

-- Registers a layout placing each panel `spacing` metres apart along x, by its options or 1.
local function registerLine(env, name, sign)
  env.layouts.service:register(env.layouts.context, {
    name = name,
    apply = function(panels, options)
      local spacing = if options then options.spacing else 1
      for index, panel in ipairs(panels) do
        panel:setPose(lovr.math.newMat4():translate(sign * index * spacing, 0, 0))
      end
    end,
  })
end

test('the workspace entry may come last: the tag it selects is held, not made', function()
  -- A saved mirror and an adopted window join the tag before the workspace starts.
  local fake = testing.native()
  fake.events.saved = 'return { version = 1, entries = { { kind = "monitor", key = "fixture-output", slot = 1, '
    .. 'pose = "1 0 0 0 0 1 0 0 0 0 1 0 0 1 -2 1", tags = { "main" } } } }'
  local monitor = fake.newMonitor 'fixture-output'
  fake.events.monitors[monitor.id] = monitor
  local window = fake.newWindow(70)
  fake.events.windows = { window }
  local reordered, workspace = {}, nil
  for _, entry in ipairs(desktop.entries()) do
    if entry.id == 'desktop/workspace' then
      workspace = entry
    else
      reordered[#reordered + 1] = entry
    end
  end
  reordered[#reordered + 1] = workspace
  local env = start(reordered, fake)
  for id, instance in pairs(env.session.instances) do
    if id == 'desktop/manager' then
      expect.equal(instance:state(), 'inactive', id)
      local diagnostic = tostring(instance:diagnostic())
      expect.truthy(diagnostic:find('waiting for a provider of lunette/composition@1', 1, true), diagnostic)
    else
      expect.equal(instance:state(), 'active', id)
    end
  end
  local main = assert(env.tags:find 'main')
  expect.truthy(main.selected, 'the workspace selects its tag whoever made it')
  expect.truthy(main:has(env.panels.service:forSource(window)), 'the window joined the tag before the workspace')
  env.session.instances['desktop/workspace']:disable()
  expect.falsy(main.dead, 'the tag outlives the workspace while placements hold it')
  env.session:close()
end)

test("a tag's own layout arranges it, and each tag is arranged apart", function()
  local env = start(desktop.compose {
    patches = {
      {
        id = 'desktop/rules',
        config = { rules = { { match = { appId = 'mail' }, properties = { tags = { 'mail' } } } } },
      },
    },
  })
  registerLine(env, 'line', 1)
  local main = assert(env.tags:find 'main')
  local terminal, other, mail = env.native.newWindow(80), env.native.newWindow(81), env.native.newWindow(82, 'mail')
  open(env, { terminal, other, mail })
  local mailTag = assert(env.tags:find 'mail')
  local panels = env.panels.service
  expect.falsy(main:has(panels:forSource(mail)), 'a rule names the tags a window joins')
  main:setLayout(env.owner, { layout = 'line' })
  expect.near(x(panels:forSource(other)), 2, 1e-5, 'the tag layout poses its members')
  local _, mailY = panels:forSource(mail).pose:getPosition()
  expect.near(mailY, 1.5, 1e-5, 'another tag keeps the configured layout')
  mailTag:setLayout(env.owner, { layout = 'line' })
  expect.near(x(panels:forSource(mail)), 1, 1e-5, 'each tag is arranged apart')
  env.session:close()
end)

test('a window in several tags is arranged by the first selected tag, with the options of its layout', function()
  local env = start(desktop.compose {
    patches = {
      {
        id = 'desktop/rules',
        config = { rules = { { match = { appId = 'mail' }, properties = { tags = { 'main', 'mail' } } } } },
      },
      { id = 'desktop/arrange', config = { options = { line = { spacing = 10 } } } },
    },
  })
  registerLine(env, 'line', 1)
  registerLine(env, 'reverse', -1)
  local main = assert(env.tags:find 'main')
  main:setLayout(env.owner, { layout = 'line' })
  open(env, { env.native.newWindow(83), env.native.newWindow(84, 'mail') })
  local mailTag = assert(env.tags:find 'mail')
  local mailPanel = assert(env.panels.service:forSource(env.events.windows[2]))
  expect.truthy(main:has(mailPanel) and mailTag:has(mailPanel), 'the rule puts the window in both tags')
  expect.near(x(mailPanel), 20, 1e-5, 'the selected tag arranges it, with its layout options')
  mailTag:setLayout(env.owner, { layout = 'reverse' })
  expect.near(x(mailPanel), 20, 1e-5, 'an unselected tag does not take it from a selected one')
  mailTag:setSelected(env.owner, { selected = true })
  main:setSelected(env.owner, { selected = false })
  expect.near(x(mailPanel), -1, 1e-5, 'the other tag arranges it, with no options for its layout')
  main:setSelected(env.owner, { selected = true })
  expect.near(x(mailPanel), 20, 1e-5, 'the first selected tag in order wins')
  env.session:close()
end)

test("a replaced placement, a rule's where and hidden, and the adoption filter reach the panels", function()
  local bending = placementModule.define {
    name = 'bending-placement',
    panelOptions = function(properties, window, base)
      local options = base(properties, window)
      if type(properties.bend) == 'number' then
        options.curve = properties.bend
      end
      return options
    end,
  }
  local env = start(desktop.compose {
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
  })
  local bent, tray, launcher =
    env.native.newWindow(90), env.native.newWindow(91, 'tray'), env.native.newWindow(92, 'launcher')
  open(env, { bent, tray, launcher })
  local panels = env.panels.service
  expect.equal(panels:forSource(bent).curve, 0.5, 'the replaced placement forwards its property')
  expect.truthy(panels:forSource(tray).hidden, 'a rule hides a window')
  expect.equal(panels:forSource(launcher), nil, 'the filter leaves a window alone')
  env.session:close()
end)

return test

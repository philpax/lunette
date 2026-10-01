-- Captures and restores through neutral services and activation-scoped bindings.
local expect = require '@spec/expect'
local suite = require '@spec/suite'
local plugin = require '@lunette-plugin'
local lunette = require '@lunette'
local panelsContract = require '@lunette-contracts/panels'
local tagsContract = require '@lunette-contracts/tags'
local rulesContract = require '@lunette-contracts/rules'
local placementContract = require '@lunette-contracts/placement'
local persist = require '@lunette-desktop/persist'
local vocabulary = require '@lunette-contracts/vocabulary'

local spec = suite.new 'lunette-desktop.persist.arrangement'
local TOLERANCE = 1e-5

local function entry(overrides)
  local value = {
    kind = 'window',
    key = 'terminal',
    slot = 1,
    pose = '1 0 0 0 0 1 0 0 0 0 1 0 1 1.5 -2 1',
    width = 1.2,
    height = 0.7,
    tags = { 'main' },
  }
  for key, replacement in pairs(overrides or {}) do
    value[key] = replacement
  end
  return value
end

local function withServices(entries, run)
  local previousClaimLayer = lunette.claimLayer
  lunette.claimLayer = function(options)
    local claim = { dead = false, granted = false, layer = false, width = options.width, height = options.height }
    function claim:release()
      if self.dead then
        return false
      end
      self.dead = true
      return true
    end
    return claim
  end

  local runtime
  local ok, failure = pcall(function()
    local reports = {}
    local state = persist.new {
      filesystem = {
        read = function()
          return persist.render(persist.newFile(entries or {}))
        end,
        write = function()
          return true
        end,
        getSaveDirectory = function()
          return '/save'
        end,
      },
      report = function(message)
        reports[#reports + 1] = message
      end,
    }
    runtime = plugin.runtime()
    for _, name in ipairs { 'panels', 'tags', 'rules', 'placement' } do
      runtime:use(require('@lunette-plugins/' .. name).definition, {}):enable()
    end
    local context, panels, tags, rules, placement
    runtime
      :use(
        plugin.define {
          name = 'arrangement-spec-1',
          requires = {
            panels = panelsContract.capability,
            tags = tagsContract.capability,
            rules = rulesContract.capability,
            placement = placementContract.capability,
          },
          init = function(current)
            context = current
            panels = current:require(panelsContract.capability)
            tags = current:require(tagsContract.capability)
            rules = current:require(rulesContract.capability)
            placement = current:require(placementContract.capability)
          end,
        },
        {}
      )
      :enable()
    expect.truthy(context and context:active(), 'the initialized consumer')
    run(state, context, panels, tags, rules, reports, placement)
  end)
  local closeOk, closeFailure = true, nil
  if runtime then
    closeOk, closeFailure = pcall(function()
      runtime:close()
    end)
  end
  lunette.claimLayer = previousClaimLayer
  if not ok then
    error(failure)
  end
  if not closeOk then
    error(closeFailure)
  end
end

local function window(appId, id)
  return { appId = appId, id = id or 1, dead = false, width = 800, height = 600, opaque = false }
end
local function monitor(id)
  return { id = id, dead = false, width = 1920, height = 1080 }
end

spec('native claim method is restored when service work raises', function()
  local nativeClaimLayer = lunette.claimLayer
  expect.raises(function()
    withServices(nil, function()
      error 'fixture: service work failed'
    end)
  end, 'fixture: service work failed', 'the original failure')
  expect.equal(lunette.claimLayer, nativeClaimLayer, 'the native method')
end)

spec('capture keys windows on application identity and ordered slots', function()
  withServices(nil, function(state, context, panels, tags)
    panels:fromWindow(context, window('terminal', 1))
    panels:fromWindow(context, window('terminal', 2))
    panels:fromWindow(context, window('browser', 3))
    local captured = persist.entries(state:capture(panels, tags))
    expect.equal(#captured, 3, 'the entries')
    expect.equal(captured[1].key, 'terminal', 'the first key')
    expect.equal(captured[1].slot, 1, 'the first slot')
    expect.equal(captured[2].slot, 2, 'the second slot')
    expect.equal(captured[3].key, 'browser', 'the third key')
    expect.equal(captured[3].slot, 1, 'the third slot')
  end)
end)

spec('capture keys a monitor on its saved identity', function()
  withServices(nil, function(state, context, panels, tags)
    panels:fromMonitor(context, monitor 'fixture.monitor')
    local captured = persist.entries(state:capture(panels, tags))
    expect.equal(captured[1].kind, 'monitor', 'the kind')
    expect.equal(captured[1].key, 'fixture.monitor', 'the identity')
  end)
end)

spec('capture records pose, metre size, and ordered tag membership', function()
  withServices(nil, function(state, context, panels, tags)
    local panel = panels:fromWindow(context, window 'terminal', {
      pose = lovr.math.newMat4():translate(2, 3, -4),
      width = 1.6,
      height = 0.9,
    })
    tags:new(context, 'main'):add(context, panel)
    tags:new(context, 'side'):add(context, panel)
    local captured = persist.entries(state:capture(panels, tags))[1]
    expect.equal(captured.pose, vocabulary.encodePose(panel.pose), 'the pose')
    expect.near(captured.width, 1.6, TOLERANCE, 'the width')
    expect.near(captured.height, 0.9, TOLERANCE, 'the height')
    expect.equal(table.concat(captured.tags, ','), 'main,side', 'the tags')
  end)
end)

spec('sources with no stable identity are reported rather than saved', function()
  withServices(nil, function(state, context, panels, tags, _rules, reports)
    panels:fromWindow(context, window(nil))
    panels:fromMonitor(context, monitor(8))
    expect.equal(#persist.entries(state:capture(panels, tags)), 0, 'the entries')
    expect.equal(#reports, 2, 'the reports')
    expect.truthy(reports[1]:find('no identity', 1, true), 'the report')
  end)
end)

spec('destroyed panels and dead sources are not captured', function()
  withServices(nil, function(state, context, panels, tags)
    panels:fromWindow(context, window 'terminal'):destroy(context)
    local source = window('browser', 2)
    panels:fromWindow(context, source)
    source.dead = true
    expect.equal(#persist.entries(state:capture(panels, tags)), 0, 'the entries')
  end)
end)

spec('binding restores a monitor and reports unmatched entries', function()
  withServices({
    entry {
      kind = 'monitor',
      key = 'fixture.monitor',
      pose = vocabulary.encodePose(lovr.math.newMat4():translate(-1, 2, -3)),
      tags = {},
    },
    entry { kind = 'monitor', key = 'unplugged', tags = {} },
  }, function(state, context, panels, tags, rules, reports)
    local panel = panels:fromMonitor(context, monitor 'fixture.monitor')
    state:bind(context, panels, tags, rules)
    local x, y, z = panel.pose:getPosition()
    expect.near(x, -1, TOLERANCE, 'x')
    expect.near(y, 2, TOLERANCE, 'y')
    expect.near(z, -3, TOLERANCE, 'z')
    expect.near(panel.width, 1.2, TOLERANCE, 'the width')
    expect.equal(#reports, 1, 'the reports')
    expect.truthy(reports[1]:find('unplugged', 1, true), 'the unmatched identity')
  end)
end)

spec('binding restores membership on existing and newly created tags', function()
  withServices(
    { entry { kind = 'monitor', key = 'fixture.monitor', tags = { 'main', 'side' } } },
    function(state, context, panels, tags, rules)
      local panel = panels:fromMonitor(context, monitor 'fixture.monitor')
      local main = tags:new(context, 'main')
      state:bind(context, panels, tags, rules)
      expect.equal(tags:find 'main', main, 'the existing tag')
      expect.truthy(main:has(panel), 'existing membership')
      expect.truthy(tags:find('side'):has(panel), 'created membership')
    end
  )
end)

spec('binding skips invalid poses and reports them without partial resize', function()
  withServices(
    { entry { kind = 'monitor', key = 'fixture.monitor', pose = 'over there', width = 8, tags = {} } },
    function(state, context, panels, tags, rules, reports)
      local panel = panels:fromMonitor(context, monitor 'fixture.monitor', { width = 1 })
      state:bind(context, panels, tags, rules)
      expect.near(panel.width, 1, TOLERANCE, 'the unchanged size')
      expect.equal(#reports, 2, 'invalid pose and unmatched reports')
    end
  )
end)

spec('dead sources take no saved slot from a live panel', function()
  withServices(
    { entry { kind = 'monitor', key = 'fixture.monitor', tags = {} } },
    function(state, context, panels, tags, rules, reports)
      local gone = monitor 'fixture.monitor'
      panels:fromMonitor(context, gone)
      gone.dead = true
      local live = panels:fromMonitor(context, monitor 'fixture.monitor')
      state:bind(context, panels, tags, rules)
      expect.near(live.width, 1.2, TOLERANCE, 'the first slot restored')
      expect.equal(#reports, 0, 'the unmatched reports')
    end
  )
end)

spec('source keys cannot collide by concatenating an identity and a slot', function()
  local resolve = persist.source(persist.newFile {
    entry { key = 'a1', slot = 1, width = 2 },
    entry { key = 'a', slot = 11, width = 1 },
  })
  expect.near(resolve(window('a1', 1)).width, 2, TOLERANCE, 'the noncolliding width')
end)

spec('source answers a window with its saved pose, size, and tags', function()
  local file = persist.newFile { entry() }
  local properties = persist.source(file)(window 'terminal')
  expect.equal(properties.pose, persist.entries(file)[1].pose, 'the pose')
  expect.near(properties.width, 1.2, TOLERANCE, 'the width')
  expect.equal(properties.tags[1], 'main', 'the tag')
end)

spec('source answers the slot a window holds, and a dead window frees its slot', function()
  local held = persist.slots()
  local resolve = persist.source(persist.newFile { entry { width = 1 }, entry { slot = 2, width = 2 } }, held)
  local first, second = window('terminal', 1), window('terminal', 2)
  expect.near(resolve(first).width, 1, TOLERANCE, 'the first free slot')
  expect.near(resolve(second).width, 1, TOLERANCE, 'resolving takes no slot')
  held:hold(first)
  expect.near(resolve(first).width, 1, TOLERANCE, 'the held slot')
  expect.near(resolve(second).width, 2, TOLERANCE, 'the next free slot')
  held:hold(second)
  expect.falsy(resolve(window('terminal', 3)), 'the exhausted slots')
  first.dead = true
  expect.near(resolve(window('terminal', 4)).width, 1, TOLERANCE, 'a dead window frees its slot')
end)

spec('source contributes nothing for unknown or unidentified applications', function()
  local resolve = persist.source(persist.newFile { entry() })
  expect.falsy(resolve(window 'browser'), 'an unknown application')
  expect.falsy(resolve(window(nil)), 'an absent identity')
  expect.falsy(resolve(window ''), 'an empty identity')
end)

spec('persisted placement at 200 overrides rules at 100 and yields to native properties at 300', function()
  withServices({ entry() }, function(state, context, panels, tags, rules, _reports, placement)
    rules:setRules(
      context,
      { rules = { { properties = { width = 1, pose = lovr.math.newMat4():translate(0, 0, -1) } } } }
    )
    state:bind(context, panels, tags, rules)
    local source = window 'terminal'
    local panel = placement:place(context, { window = source })
    expect.near(panel.width, 1.2, TOLERANCE, 'the persisted width')
    local _, _, z = panel.pose:getPosition()
    expect.near(z, -2, TOLERANCE, 'the persisted pose')
    rules:addSource(context, {
      name = 'fixture.native',
      precedence = vocabulary.PRECEDENCE.native,
      resolve = function()
        return { width = 3 }
      end,
    })
    expect.near(rules:resolve(source).width, 3, TOLERANCE, 'the native width')
  end)
end)

spec('refused state binds an empty restore without placing panels', function()
  local reports = {}
  local state = persist.new {
    filesystem = {
      read = function()
        return 'return { version = 99, entries = {} }'
      end,
      write = function()
        error 'a refused state must not write'
      end,
      getSaveDirectory = function()
        return '/save'
      end,
    },
    report = function(message)
      reports[#reports + 1] = message
    end,
  }
  withServices(nil, function(_empty, context, panels, tags, rules)
    local panel = panels:fromMonitor(context, monitor 'fixture.monitor', { width = 1 })
    state:bind(context, panels, tags, rules)
    expect.near(panel.width, 1, TOLERANCE, 'the untouched panel')
    expect.equal(next(rules:resolve(window 'terminal')), nil, 'the empty source')
  end)
  expect.equal(#reports, 1, 'the refusal report')
end)

spec('failed registration rolls back the source when a foreign panels service rejects the owner', function()
  withServices(nil, function(state, context, _panels, tags, rules)
    local foreign = plugin.runtime()
    foreign:use(require('@lunette-plugins/panels').definition, {}):enable()
    local foreignPanels
    foreign
      :use(
        plugin.define {
          name = 'arrangement-spec-2',
          requires = { panels = panelsContract.capability },
          init = function(current)
            foreignPanels = current:require(panelsContract.capability)
          end,
        },
        {}
      )
      :enable()
    local ok, failure = pcall(function()
      expect.truthy(foreignPanels, 'the foreign service')
      expect.raises(function()
        state:bind(context, foreignPanels, tags, rules)
      end, 'another runtime', 'the rejected owner')
      expect.equal(#rules:sources(), 0, 'the rolled-back source')
    end)
    foreign:close()
    if not ok then
      error(failure)
    end
  end)
end)

spec('binding rejects a context whose activation has ended', function()
  local state, context, panels, tags, rules
  withServices(nil, function(currentState, currentContext, currentPanels, currentTags, currentRules)
    state, context, panels, tags, rules = currentState, currentContext, currentPanels, currentTags, currentRules
  end)
  expect.raises(function()
    state:bind(context, panels, tags, rules)
  end, 'no longer active', 'the ended activation')
end)

return spec

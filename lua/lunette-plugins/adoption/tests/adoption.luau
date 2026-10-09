local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adoptionContract = require '@lunette-contracts/adoption'
local panelsContract = require '@lunette-contracts/panels'
local placementContract = require '@lunette-contracts/placement'
local rulesContract = require '@lunette-contracts/rules'
local tagsContract = require '@lunette-contracts/tags'
local vocabulary = require '@lunette-contracts/vocabulary'

local test = testing.suite()

local function start()
  local env = { native = testing.native() }
  env.session = testing.start {
    'theme',
    { id = 'panels', definition = require('@lunette-plugins/panels').definition, config = { rendering = 'layer' } },
    'tags',
    'rules',
    'placement',
    'adoption',
  }
  env.consumer = env.session:use(plugin.define {
    name = 'adoption-test',
    requires = {
      panels = panelsContract.capability,
      placement = placementContract.capability,
      tags = tagsContract.capability,
      rules = rulesContract.capability,
      adoption = adoptionContract.capability,
    },
    init = function(context)
      env.panels = context:require(panelsContract.capability)
      env.placement = context:require(placementContract.capability)
      env.tags = context:require(tagsContract.capability)
      env.rules = context:require(rulesContract.capability)
      env.adoption = context:require(adoptionContract.capability)
      env.owner = context
    end,
  })
  return env
end

local function pose(x)
  local values = {}
  for index = 1, 16 do
    values[index] = if index == 13 then x elseif index == 1 or index == 6 or index == 11 or index == 16 then 1 else 0
  end
  return table.concat(values, ' ')
end

local function lastCallback(env)
  local list = env.native.events.subscriptions.onWindowOpened
  return list[#list].callback
end

local function caller(env, name, run)
  return env.session.runtime:use(
    plugin.define {
      name = name,
      requires = { adoption = adoptionContract.capability },
      init = function(context)
        run(context, context:require(adoptionContract.capability))
      end,
    },
    {}
  )
end

test('start subscribes, then adopts each window once with its resolved properties', function()
  local env = start()
  local fake = env.native
  local persisted = env.rules:addSource(env.owner, {
    name = 'persistence',
    precedence = 200,
    resolve = function()
      return { title = 'persisted-title', pose = pose(2) }
    end,
  })
  local installed = env.adoption:install(env.owner)
  local saved, ordinary = fake.newWindow(1), fake.newWindow(2)
  saved.properties[vocabulary.POSE_PROPERTY] = pose(3)
  fake.events.windows = { saved, ordinary }
  local started = env.adoption:start(env.owner)
  local placed = env.placement:placed()
  expect.equal(fake.events.enumerations, 1, 'the enumerations')
  expect.equal(#placed, 2, 'the windows placed')
  expect.equal(placed[1].properties.title, 'persisted-title', 'the title a lower source gives')
  expect.equal(placed[1].properties.pose, pose(3), 'the pose the window kept, above the persisted one')
  expect.equal(placed[2].properties.pose, pose(2), 'the persisted pose of a window that kept none')
  expect.equal(#env.panels:all(), 2, 'the panels')

  fake.emit('onWindowOpened', { window = saved })
  expect.equal(#env.placement:placed(), 2, 'an adopted window opening again')
  fake.emit('onWindowOpened', { window = fake.newWindow(3) })
  expect.equal(#env.placement:placed(), 3, 'an arriving window')
  expect.equal(#env.panels:all(), 3, 'the panels after the arrival')

  local stale = lastCallback(env)
  started:dispose()
  expect.equal(fake.subscriptionCount 'onWindowOpened', 0, 'the subscriptions after the dispose')
  expect.equal(#env.panels:all(), 0, 'disposing the start releases its panels')
  stale { window = fake.newWindow(4) }
  expect.equal(#env.panels:all(), 0, 'a stale callback is inert')

  local again = env.adoption:start(env.owner)
  expect.equal(fake.events.enumerations, 2, 'the enumerations of the second start')
  expect.equal(#env.panels:all(), 2, 'the surviving windows adopted again')
  again:dispose()
  installed:dispose()
  persisted:dispose()
  env.session:close()
end)

test('a window the filter refuses, or a rule gives adopt = false, is left alone', function()
  local env = start()
  local fake = env.native
  local refused, declined, accepted =
    fake.newWindow(6, 'fixture.refused'), fake.newWindow(7, 'fixture.declined'), fake.newWindow(8)
  fake.events.windows = { refused, declined, accepted }
  local declining = env.rules:addSource(env.owner, {
    name = 'fixture.declining',
    precedence = vocabulary.PRECEDENCE.rules,
    resolve = function(target)
      return if target.appId == 'fixture.declined' then { adopt = false } else nil
    end,
  })
  local filtered = env.adoption:start(env.owner, {
    filter = function(target)
      return target.appId ~= 'fixture.refused'
    end,
  })
  expect.falsy(env.panels:forSource(refused), 'the refused window')
  expect.falsy(env.panels:forSource(declined), 'the declined window')
  expect.truthy(env.panels:forSource(accepted), 'the accepted window')
  filtered:dispose()
  declining:dispose()
  env.session:close()
end)

-- Each way a start can end: disposing it, and disabling the consumer.
local ENDINGS = { 'dispose', 'disable' }

test('every way a start ends releases its panel, claim, tags, and window', function()
  local env = start()
  local fake = env.native
  local existing = env.tags:hold(env.owner, { name = 'existing-adoption-tag' })
  local placed = 0
  env.placement:onPlaced(env.owner, {
    run = function()
      placed += 1
    end,
  })
  for round = 1, 2 * #ENDINGS do
    local ending = ENDINGS[(round - 1) % #ENDINGS + 1]
    local claimsBefore = #fake.events.claims
    placed = 0
    do
      local target = fake.newWindow(400 + round)
      fake.events.windows = { target }
      local options = {
        defaults = { tags = { 'temporary-adoption-tag', 'existing-adoption-tag' } },
      }
      if ending == 'dispose' then
        local started = env.adoption:start(env.owner, options)
        expect.truthy(env.tags:find 'temporary-adoption-tag', ending .. ': the implicit tag placement made')
        started:dispose()
      else
        local consumer = caller(env, 'adoption-test-' .. ending, function(context, adoption)
          adoption:start(context, options)
        end)
        consumer:enable()
        consumer:disable()
        consumer:dispose()
      end
      fake.events.windows = {}
    end
    expect.equal(placed, 1, ending .. ': the placements')
    expect.equal(#env.panels:all(), 0, ending .. ': the panels')
    expect.equal(#fake.events.claims, claimsBefore + 1, ending .. ': the claims made')
    expect.truthy(fake.events.claims[#fake.events.claims].dead, ending .. ': the claim')
    expect.equal(fake.subscriptionCount 'onWindowOpened', 0, ending .. ': the subscriptions')
    expect.falsy(env.tags:find 'temporary-adoption-tag', ending .. ': the tag placement made')
    expect.equal(env.tags:find 'existing-adoption-tag', existing, ending .. ': the existing tag')
    expect.equal(#existing:panels(), 0, ending .. ': the members of the existing tag')
    lastCallback(env) { window = fake.newWindow(900 + round) }
    expect.equal(placed, 1, ending .. ': the placements after a copied callback runs')
    expect.equal(#env.panels:all(), 0, ending .. ': the panels after a copied callback runs')
    fake.dropEndedSubscriptions()
  end
  expect.truthy(env.owner:active(), 'the consumer that watched')
  expect.equal(#testing.ruleSources(env.rules), 0, 'the rules sources left')
  env.session:close()
end)

return test

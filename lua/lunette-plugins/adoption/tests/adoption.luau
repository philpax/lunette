local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adoptionContract = require '@lunette-contracts/adoption'
local panelsContract = require '@lunette-contracts/panels'
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
      tags = tagsContract.capability,
      rules = rulesContract.capability,
      adoption = adoptionContract.capability,
    },
    init = function(context)
      env.panels = context:require(panelsContract.capability)
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

test('install registers the native pose source above the other sources and enumerates nothing', function()
  local env = start()
  local low = env.rules:addSource(env.owner, {
    name = 'caller.rules',
    precedence = 100,
    resolve = function()
      return nil
    end,
  })
  local installed = env.adoption:install(env.owner)
  local sources = env.rules:sources()
  expect.equal(#sources, 2, 'the sources')
  expect.equal(sources[1].name, 'caller.rules', 'the lower source')
  expect.equal(sources[2].name, 'lunette.adoption', 'the native source')
  expect.equal(sources[2].precedence, vocabulary.PRECEDENCE.native, 'the native precedence')
  expect.equal(env.native.events.enumerations, 0, 'the enumerations install made')
  installed:dispose()
  expect.equal(#env.rules:sources(), 1, 'the sources after the install ends')
  low:dispose()
  env.session:close()
end)

test('a caller requiring adoption alone installs the source, which ends with the caller', function()
  local env = start()
  local function registered()
    for _, source in env.rules:sources() do
      if source.name == 'lunette.adoption' and source.precedence == 250 then
        return true
      end
    end
    return false
  end
  local installer = caller(env, 'adoption-test-installer', function(context, adoption)
    adoption:install(context, { precedence = 250 })
  end)
  installer:enable()
  expect.equal(installer:state(), 'active', 'the installer')
  expect.truthy(registered(), 'the source after the install')
  installer:disable()
  expect.falsy(registered(), 'the source after the installer ends')
  env.session:close()
end)

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
  local placed = {}
  local started = env.adoption:start(env.owner, {
    onPlaced = function(panel, resolved)
      placed[#placed + 1] = { panel = panel, resolved = resolved }
    end,
  })
  expect.equal(fake.events.enumerations, 1, 'the enumerations')
  expect.equal(#placed, 2, 'the windows placed')
  expect.equal(placed[1].resolved.title, 'persisted-title', 'the title a lower source gives')
  expect.equal(placed[1].resolved.pose, pose(3), 'the pose the window kept, above the persisted one')
  expect.equal(placed[2].resolved.pose, pose(2), 'the persisted pose of a window that kept none')
  expect.equal(#env.panels:all(), 2, 'the panels')

  fake.emit('onWindowOpened', { window = saved })
  expect.equal(#placed, 2, 'an adopted window opening again')
  fake.emit('onWindowOpened', { window = fake.newWindow(3) })
  expect.equal(#placed, 3, 'an arriving window')
  expect.equal(#env.panels:all(), 3, 'the panels after the arrival')

  local stale = lastCallback(env)
  started:dispose()
  expect.equal(fake.subscriptionCount 'onWindowOpened', 0, 'the subscriptions after the dispose')
  expect.equal(#env.panels:all(), 0, 'disposing the start releases its panels')
  stale { window = fake.newWindow(4) }
  expect.equal(#env.panels:all(), 0, 'a stale callback is inert')

  -- A second start enumerates the windows that survived once.
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
  expect.raises(function()
    env.adoption:start(env.owner, { filter = 'everything' })
  end, 'filter is a function', 'a filter that is not a function')
  env.session:close()
end)

test('a consumer whose onPlaced raises fails to load, and releases everything it adopted', function()
  local env = start()
  local fake = env.native
  fake.events.windows = { fake.newWindow(101), fake.newWindow(102) }
  local placements = 0
  local failedOwner
  local failed = caller(env, 'adoption-test-failing', function(context, adoption)
    failedOwner = context
    adoption:start(context, {
      onPlaced = function()
        placements += 1
        if placements == 2 then
          error 'fixture: onPlaced failure'
        end
      end,
    })
  end)
  failed:enable()
  local reports = testing.takeReports()
  expect.equal(#reports, 1, 'the reports')
  expect.truthy(reports[1]:find('fixture: onPlaced failure', 1, true), 'the reported failure')
  expect.falsy(failedOwner:active(), 'the failed consumer')
  expect.equal(#env.panels:all(), 0, 'the panels after the failure')
  expect.equal(fake.subscriptionCount 'onWindowOpened', 0, 'the subscriptions after the failure')
  expect.equal(#fake.events.claims, 2, 'the claims made')
  for index, claim in fake.events.claims do
    expect.truthy(claim.dead, 'claim ' .. index)
  end
  local later = fake.newWindow(103)
  lastCallback(env) { window = later }
  expect.equal(placements, 2, 'the placements after a copied callback runs')
  expect.falsy(env.panels:forSource(later), 'the window the copied callback was given')
  env.session:close()
end)

test('a start that fails or is cancelled leaves its callbacks inert, and a retry adopts cleanly', function()
  local env = start()
  local fake = env.native
  local enumerate = require('@lunette').windows

  -- A caught enumeration failure unsubscribes at once.
  require('@lunette').windows = function()
    error 'fixture: enumeration failure'
  end
  expect.raises(function()
    env.adoption:start(env.owner)
  end, 'fixture: enumeration failure', 'the failing start')
  require('@lunette').windows = enumerate
  expect.equal(fake.subscriptionCount 'onWindowOpened', 0, 'the subscriptions after the failure')
  local later = fake.newWindow(104)
  lastCallback(env) { window = later }
  expect.falsy(env.panels:forSource(later), 'the window a failed start was given')
  fake.events.windows = { later }
  local retry = env.adoption:start(env.owner)
  expect.truthy(env.panels:forSource(later), 'the window the retry enumerated')
  retry:dispose()

  -- A disabled caller's copied callback is inert.
  fake.events.windows = { fake.newWindow(201) }
  local placements = 0
  local cancelling = false
  local cancelled
  local function cancel()
    cancelled:disable()
    lastCallback(env) { window = fake.newWindow(203) }
  end
  cancelled = caller(env, 'adoption-test-cancelled', function(context, adoption)
    adoption:start(context, {
      onPlaced = function()
        placements += 1
      end,
    })
  end)
  cancelled:enable()
  expect.equal(placements, 1, 'the placements of the caller')
  local copied = lastCallback(env)
  cancelled:disable()
  copied { window = fake.newWindow(202) }
  expect.equal(#env.panels:all(), 0, 'the panels after the caller is disabled')
  expect.equal(placements, 1, 'the placements after a copied callback runs')

  -- A caller cancelled while it enumerates places nothing.
  require('@lunette').windows = function()
    local existing = enumerate()
    if cancelling then
      cancel()
    end
    return existing
  end
  cancelling = true
  cancelled:enable()
  require('@lunette').windows = enumerate
  expect.equal(placements, 1, 'the placements of a cancelled enumeration')
  expect.equal(#env.panels:all(), 0, 'the panels of a cancelled enumeration')
  expect.equal(fake.subscriptionCount 'onWindowOpened', 0, 'the subscriptions after the cancellation')
  env.session:close()
end)

-- Each way a start can end: disposing it, a raise from onPlaced caught by the caller, a raise that fails the
-- consumer's load, and disabling the consumer.
local ENDINGS = { 'dispose', 'caught', 'failed-consumer', 'disable' }

test('every way a start ends releases its panel, claim, tags, and window', function()
  local env = start()
  local fake = env.native
  local existing = env.tags:new(env.owner, 'existing-adoption-tag')
  local weak = setmetatable({}, { __mode = 'v' })
  for round = 1, 2 * #ENDINGS do
    local ending = ENDINGS[(round - 1) % #ENDINGS + 1]
    local claimsBefore = #fake.events.claims
    local placed = 0
    do
      local target = fake.newWindow(400 + round)
      weak[round] = target
      fake.events.windows = { target }
      local options = {
        defaults = { tags = { 'temporary-adoption-tag', 'existing-adoption-tag' } },
        onPlaced = function()
          placed += 1
          if ending == 'caught' or ending == 'failed-consumer' then
            error 'fixture: placement lifetime failure'
          end
        end,
      }
      if ending == 'dispose' then
        local started = env.adoption:start(env.owner, options)
        expect.truthy(env.tags:find 'temporary-adoption-tag', ending .. ': the implicit tag placement made')
        started:dispose()
      elseif ending == 'caught' then
        expect.raises(function()
          env.adoption:start(env.owner, options)
        end, 'fixture: placement lifetime failure', ending)
      else
        local consumer = caller(env, 'adoption-test-' .. ending, function(context, adoption)
          adoption:start(context, options)
        end)
        consumer:enable()
        if ending == 'disable' then
          consumer:disable()
        else
          local reports = testing.takeReports()
          expect.equal(#reports, 1, ending .. ': the reports')
          expect.truthy(reports[1]:find('fixture: placement lifetime failure', 1, true), ending .. ': the report')
        end
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
    testing.collect()
    testing.collect()
    expect.equal(weak[round], nil, ending .. ': the window after the start ended')
  end
  expect.truthy(env.owner:active(), 'the consumer that watched')
  expect.equal(#env.rules:sources(), 0, 'the rules sources left')
  env.session:close()
end)

return test

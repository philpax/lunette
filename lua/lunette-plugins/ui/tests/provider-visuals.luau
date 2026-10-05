local testing = require '@testing'
local expect = testing.expect
local substitute = require '@testing/ui-substitute'
local fixture = require './support/panel'
local test = testing.suite()

local function run(provider, options, scenario)
  options.provider = provider
  local state = fixture.boot(options)
  local ok, failure = pcall(scenario, state)
  local closed, cleanup = pcall(fixture.closeAll)
  if not ok then
    error(tostring(failure) .. (if closed then '' else '\ncleanup: ' .. tostring(cleanup)), 0)
  end
  if not closed then
    error(cleanup, 0)
  end
end

local function immutable(value, path)
  if type(value) ~= 'table' then
    return
  end
  expect.truthy(table.isfrozen(value), path .. ' is frozen')
  expect.raises(function()
    value.snapshotMutation = true
  end, nil, path .. ' rejects mutation')
  for key, child in value do
    immutable(child, path .. '.' .. tostring(key))
  end
end

local function control(description, id)
  for _, value in description.controls do
    if value.id == id then
      return value
    end
  end
  error('missing described control ' .. id)
end

local function cloneVisual(visual)
  local result = table.clone(visual)
  result.bounds = table.clone(visual.bounds)
  result.clip = table.clone(visual.clip)
  result.theme = table.clone(visual.theme)
  result.items = {}
  for index, item in visual.items do
    local copy = table.clone(item)
    copy.bounds = if item.bounds then table.clone(item.bounds) else nil
    if item.route then
      copy.route = {}
      for pointIndex, point in item.route do
        copy.route[pointIndex] = table.clone(point)
      end
    end
    result.items[index] = copy
  end
  return result
end

local replacements = {
  {
    name = 'bounds',
    change = function(value)
      value.bounds.x += 1
    end,
  },
  {
    name = 'clip',
    change = function(value)
      value.clip.width += 1
    end,
  },
  {
    name = 'item count',
    change = function(value)
      table.remove(value.items)
    end,
  },
  {
    name = 'item identity',
    change = function(value)
      value.items[1].id = 'replacement'
    end,
  },
  {
    name = 'item bounds',
    change = function(value)
      value.items[1].bounds.y += 1
    end,
  },
  {
    name = 'item bounds removal',
    change = function(value)
      value.items[1].bounds = nil
    end,
  },
  {
    name = 'route point',
    change = function(value)
      value.items[1].route[1].x += 1
    end,
  },
  {
    name = 'route length',
    change = function(value)
      table.remove(value.items[1].route)
    end,
  },
  {
    name = 'route removal',
    change = function(value)
      value.items[1].route = nil
    end,
  },
}

for _, provider in
  {
    { name = 'builtin', entry = 'ui' },
    { name = 'independent substitute', entry = { id = 'ui', definition = substitute.definition } },
  }
do
  test(provider.name .. ' descriptions are detached immutable snapshots', function()
    run(provider.entry, {}, function(state)
      local first = state.panel:describe()
      immutable(first, 'description')
      expect.raises(function()
        first.controls[1].label = 'Changed'
      end, nil, 'control records reject mutation')
      local region = control(first, 'custom')
      expect.raises(function()
        region.items[1].route[1].x = -1
      end, nil, 'route points reject mutation')
      state.button:setBounds { x = 30, y = 10, width = 80, height = 40 }
      state.region:setItems {
        {
          id = 'new-node',
          label = 'New node',
          bounds = { x = 30, y = 270, width = 20, height = 10 },
          route = { { x = 30, y = 270 }, { x = 50, y = 280 } },
        },
      }
      state.panel:setSize(2, 1.5, 500, 350)
      local second = state.panel:describe()
      expect.truthy(first ~= second and first.controls ~= second.controls, 'description arrays are detached')
      expect.equal(control(first, 'run').bounds.x, 10, 'retained bounds do not change')
      expect.equal(first.logicalWidth, 400, 'retained panel size does not change')
      expect.equal(region.items[1].id, 'node', 'retained items do not change')
      expect.equal(region.items[1].route[1].x, 20, 'retained routes do not change')
      expect.equal(control(second, 'run').bounds.x, 30, 'fresh bounds reflect the setter')
      expect.equal(control(second, 'custom').items[1].id, 'new-node', 'fresh items reflect the setter')
      immutable(second, 'fresh description')
    end)
  end)

  test(provider.name .. ' panel enumeration is a detached immutable array', function()
    run(provider.entry, {}, function(state)
      local first = state.service:panels()
      expect.truthy(table.isfrozen(first), 'panel array is frozen')
      expect.raises(function()
        first[1] = nil
      end, nil, 'panel array rejects mutation')
      expect.equal(first[1], state.panel, 'enumeration preserves handle identity')
      state.panel:destroy()
      local second = state.service:panels()
      expect.equal(#second, 0, 'fresh enumeration reflects removal')
      expect.equal(#first, 1, 'retained enumeration preserves membership')
      expect.truthy(first ~= second and table.isfrozen(second), 'fresh enumeration is detached and frozen')
    end)
  end)

  test(provider.name .. ' visual records and routes are detached immutable snapshots', function()
    local heard = {}
    run(provider.entry, {}, function(state)
      state.panel:region(state.owner, {
        id = 'snapshot-region',
        bounds = { x = 20, y = 260, width = 100, height = 30 },
        items = {
          {
            id = 'route',
            bounds = { x = 20, y = 265, width = 20, height = 20 },
            route = { { x = 20, y = 265 }, { x = 40, y = 285 } },
          },
        },
        draw = function(pass, visual, base)
          heard[#heard + 1] = visual
          base(pass, visual)
        end,
      })
      state.panel:draw(state.fixture.native.events.render.pass)
      local first = assert(heard[1])
      immutable(first, 'visual')
      expect.raises(function()
        first.clip.x = -100
      end, nil, 'visual clip rejects mutation')
      expect.raises(function()
        first.items[1].label = 'Changed'
      end, nil, 'visual items reject mutation')
      local background = first.theme.background[1]
      state.panel:setTheme { background = { 0.7, 0.2, 0.3, 1 } }
      state.panel:setSize(2, 1.5, 500, 350)
      state.panel:draw(state.fixture.native.events.render.pass)
      local second = assert(heard[2])
      expect.truthy(first ~= second and first.clip ~= second.clip, 'visual records and bounds are detached')
      expect.truthy(first.items ~= second.items, 'visual item arrays are detached')
      expect.truthy(first.items[1].route ~= second.items[1].route, 'visual routes are detached')
      expect.equal(first.theme.background[1], background, 'retained visual theme does not change')
      expect.equal(second.theme.background[1], 0.7, 'fresh visual theme reflects the setter')
    end)
  end)

  test(provider.name .. ' control hooks wrap panel hooks in consistent order', function()
    local calls, retained = {}, nil
    run(provider.entry, {
      draw = function(pass, visual, base)
        if visual.id == 'wrapped' then
          retained = visual
        end
        calls[#calls + 1] = visual.id .. ':panel-before:' .. visual.label
        base(pass, visual)
        calls[#calls + 1] = visual.id .. ':panel-after'
      end,
    }, function(state)
      state.panel:button(state.owner, {
        id = 'wrapped',
        label = 'Wrapped',
        bounds = { x = 100, y = 260, width = 80, height = 30 },
        onActivate = function() end,
        draw = function(pass, visual, base)
          calls[#calls + 1] = visual.id .. ':control-before'
          local replacement = cloneVisual(visual)
          replacement.label = 'Styled'
          replacement.theme.background = { 0.6, 0.3, 0.2, 1 }
          base(pass, replacement)
          replacement.theme.background[1] = 0.9
          calls[#calls + 1] = visual.id .. ':control-after'
        end,
      })
      state.panel:draw(state.fixture.native.events.render.pass)
      local wrapped, ordinary = {}, false
      for _, call in calls do
        if call:find '^wrapped:' then
          wrapped[#wrapped + 1] = call
        end
        ordinary = ordinary or call == 'run:panel-before:Run'
      end
      expect.truthy(ordinary, 'panel hook wraps controls without a control hook')
      expect.equal(
        table.concat(wrapped, ','),
        'wrapped:control-before,wrapped:panel-before:Styled,wrapped:panel-after,wrapped:control-after',
        'control hook wraps the panel hook and can replace presentation'
      )
      immutable(assert(retained), 'inner hook visual')
      expect.equal(retained.theme.background[1], 0.6, 'replacement mutation cannot change a retained inner snapshot')
      expect.equal(
        control(state.panel:describe(), 'wrapped').label,
        'Wrapped',
        'render replacement does not alter state'
      )
    end)
  end)

  for _, replacement in replacements do
    test(provider.name .. ' base renderer rejects replacement ' .. replacement.name, function()
      run(provider.entry, {}, function(state)
        local called, accepted, failure = false, nil, nil
        state.panel:region(state.owner, {
          id = 'guarded-region',
          bounds = { x = 20, y = 260, width = 100, height = 30 },
          items = {
            {
              id = 'route',
              bounds = { x = 20, y = 265, width = 20, height = 20 },
              route = { { x = 20, y = 265 }, { x = 40, y = 285 } },
            },
          },
          draw = function(pass, visual, base)
            called = true
            local changed = cloneVisual(visual)
            replacement.change(changed)
            accepted, failure = pcall(base, pass, changed)
            base(pass, visual)
          end,
        })
        local recorder = state.fixture.native.events.render
        local checkpoint = recorder:checkpoint()
        state.panel:draw(recorder.pass)
        expect.truthy(called, 'control hook ran')
        expect.equal(accepted, false, replacement.name .. ' replacement is rejected')
        expect.truthy(tostring(failure):find 'hook cannot', 'rejection names the hook constraint')
        recorder:assertRestored(checkpoint)
      end)
    end)
  end
end

return test

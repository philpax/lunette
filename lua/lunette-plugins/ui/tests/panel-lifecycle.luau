local testing = require '@testing'
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local focus = require '@lunette-contracts/focus'
local surfaces = require '@lunette-contracts/surfaces'
local vrUi = require '@testing/vr-ui'
local expect = testing.expect
local test = testing.suite()

local function withSession(running, run)
  local ok, failure = pcall(run, running)
  running:close()
  if not ok then
    error(failure, 0)
  end
end

local function owner(running, name, init)
  return running:use(plugin.define {
    name = name,
    requires = { ui = ui.capability },
    init = function(context)
      init(context, context:require(ui.capability))
    end,
  })
end

local function options(name, draw)
  return {
    name = name,
    pose = lovr.math.newMat4():translate(0, 1.5, -2),
    width = 2,
    height = 1,
    logicalWidth = 200,
    logicalHeight = 100,
    draw = draw,
  }
end

local function armed(running, instance)
  for _, entry in ipairs(running.runtime:snapshot().instances) do
    if entry.id == instance:id() then
      local count = 0
      for _, effect in ipairs(entry.effects) do
        if effect.state == 'armed' then
          count += 1
        end
      end
      return count
    end
  end
  error 'missing owner snapshot'
end

local function substituteServices(state)
  return {
    id = 'lifecycle-services',
    definition = plugin.define {
      name = 'testing/panel-lifecycle-services',
      provides = { focus = focus.capability, surfaces = surfaces.capability },
      init = function(context, _config, publish)
        publish:provide(focus.capability, {
          focused = function()
            state.focusReads += 1
            return state.focused
          end,
          register = function(_self, targetOwner, spec)
            local target = { dead = false }
            local index = #state.targets + 1
            local release
            local function destroy()
              if target.dead then
                return false
              end
              target.dead = true
              state.destroyed[#state.destroyed + 1] = index
              state.observedCounts[#state.observedCounts + 1] = #state.panel:describe().controls
              if state.focused == target then
                state.focused = nil
              end
              if index == 1 and state.failFirst then
                error 'first target inverse fails'
              end
              return true
            end
            target.focus = function()
              state.focused = target
              return true
            end
            target.blur = function()
              if state.focused ~= target then
                return false
              end
              state.focused = nil
              if spec.receiver.onBlur then
                spec.receiver.onBlur { target = nil, revision = 1, kind = 'none', wantsKeyboard = false }
              end
              return true
            end
            target.destroy = function()
              local inverse = release
              release = nil
              if inverse then
                inverse:dispose()
                return true
              end
              return destroy()
            end
            release = context:acquire(targetOwner, function()
              return function()
                release = nil
                destroy()
              end
            end)
            state.targets[#state.targets + 1] = target
            return target
          end,
        })
        publish:provide(surfaces.capability, {
          offer = function(_self, surfaceOwner)
            return context:acquire(surfaceOwner, function()
              return function()
                state.surfaceInverses += 1
                expect.equal(#state.panel:describe().controls, 0, 'panel controls detach before the surface inverse')
              end
            end)
          end,
        })
      end,
    },
  }
end

for _, focused in ipairs { false, true } do
  test('panel disposal isolates control inverses with focus ' .. tostring(focused), function()
    local state =
      { targets = {}, destroyed = {}, observedCounts = {}, surfaceInverses = 0, focusReads = 0, failFirst = false }
    local font = require('@testing/render').new().font
    lovr.graphics = {
      getDefaultFont = function()
        return font
      end,
    }
    withSession(testing.start { 'theme', substituteServices(state), 'ui' }, function(running)
      owner(running, 'testing/panel-lifetime', function(context, service)
        state.service = service
        state.panel = service:newPanel(context, options 'lifecycle')
      end)
      local controls, instances, effectCounts = {}, {}, {}
      for index = 1, 2 do
        instances[index] = owner(running, 'testing/control-lifetime-' .. index, function(context)
          controls[index] = state.panel:textField(context, {
            id = 'field-' .. index,
            bounds = { x = index * 20, y = 10, width = 20, height = 20 },
          })
        end)
        effectCounts[index] = armed(running, instances[index])
        expect.truthy(effectCounts[index] > 0, 'each control owner retains a cleanup effect')
      end
      if focused then
        controls[1]:focus()
      end
      local retained = state.panel:describe()
      state.failFirst = true
      local ok, failure = pcall(state.panel.destroy, state.panel)
      state.failFirst = false
      expect.falsy(ok, 'the inverse failure reaches the caller')
      expect.truthy(
        tostring(failure):find('first target inverse fails', 1, true),
        'the original inverse failure is retained'
      )
      expect.equal(table.concat(state.destroyed, ','), '1,2', 'both independent target inverses run')
      expect.equal(table.concat(state.observedCounts, ','), '0,0', 'panel controls detach before target observers')
      expect.equal(state.surfaceInverses, 1, 'the surface inverse runs after target failure')
      expect.truthy(controls[1].dead and controls[2].dead, 'both controls are dead')
      expect.equal(#state.panel:describe().controls, 0, 'dead panel descriptions contain no controls')
      expect.equal(#state.service:panels(), 0, 'the panel registry is detached')
      expect.equal(#retained.controls, 2, 'retained descriptions remain detached snapshots')
      for index, instance in ipairs(instances) do
        expect.equal(
          armed(running, instance),
          effectCounts[index] - 1,
          'panel disposal disarms the acquired control effect'
        )
      end
      expect.equal(state.panel:destroy(), false, 'a second panel disposal is inert')
      expect.equal(table.concat(state.destroyed, ','), '1,2', 'a second disposal retries no target')
      expect.equal(state.surfaceInverses, 1, 'a second disposal repeats no surface inverse')
      expect.equal(state.focusReads, 0, 'destruction needs no focused-target query')
    end)
  end)
end

local entries =
  { 'theme', 'frame', 'surfaces', 'drops', 'focus', 'interaction', 'laser', 'keyboard', 'desktop/pointing', 'ui' }

for _, showAgain in ipairs { false, true } do
  test('panel hiding preserves focus selected by cancellation with reshow ' .. tostring(showAgain), function()
    local fixture = vrUi.boot(entries)
    withSession(fixture, function()
      local panel, otherPanel, field, replacement, replacementTarget, cancellations, selectedAfterCancel, observed
      cancellations = 0
      owner(fixture.session, 'testing/hide-focus', function(context, service)
        panel = service:newPanel(context, options 'hidden-focus')
        otherPanel = if showAgain then panel else service:newPanel(context, options 'other-focus')
        field = panel:textField(context, { id = 'before-hide', bounds = { x = 0, y = 0, width = 40, height = 20 } })
        replacement = otherPanel:textField(context, {
          id = 'after-hide',
          bounds = { x = 100, y = 0, width = 40, height = 20 },
        })
        panel:region(context, {
          id = 'captured',
          bounds = { x = 0, y = 40, width = 40, height = 20 },
          onPointer = function(event)
            if event.kind == 'cancel' then
              cancellations += 1
              if showAgain then
                panel:setVisible(true)
              end
              replacementTarget:focus()
              selectedAfterCancel = observed.service:focused()
            end
          end,
        })
      end)
      observed = fixture.session:observe(focus.capability)
      replacement:focus()
      replacementTarget = observed.service:focused()
      field:focus()
      fixture:aim(panel:describe(), 20, 50)
      fixture:step()
      fixture:button('right', 'trigger', true)
      fixture:step()
      panel:setVisible(false)
      expect.equal(cancellations, 1, 'hide cancels the captured region once')
      local selected = observed.service:focused()
      expect.truthy(selected, 'the cancellation callback selects a new focus target')
      expect.equal(selected, selectedAfterCancel, 'hide does not clear replacement focus')
      fixture:button('right', 'trigger', false)
      fixture:step()
    end)
  end)
end

for _, equalZ in ipairs { false, true } do
  test('painting and real pointer picking share overlap order with equal z ' .. tostring(equalZ), function()
    local fixture = vrUi.boot(entries)
    withSession(fixture, function()
      local panel, activated, painted = nil, {}, {}
      owner(fixture.session, 'testing/overlap-order', function(context, service)
        panel = service:newPanel(context, options 'overlap')
        for index, id in ipairs { 'first', 'second' } do
          panel:button(context, {
            id = id,
            bounds = { x = 10, y = 10, width = 40, height = 30 },
            z = if equalZ then 2 elseif index == 1 then 10 else -1,
            onActivate = function()
              activated[#activated + 1] = id
            end,
            draw = function(pass, visual, base)
              painted[#painted + 1] = visual.id
              base(pass, visual)
            end,
          })
        end
      end)
      panel:draw(fixture.native.events.pass)
      local top = if equalZ then 'second' else 'first'
      expect.equal(painted[#painted], top, 'the winning control paints last')
      local description = panel:describe()
      expect.equal(description.controls[#description.controls].id, top, 'descriptions use the same control order')
      fixture:click(description, 30, 25)
      expect.equal(table.concat(activated, ','), top, 'the actual pointer activates the last painted control')
    end)
  end)
end

for _, phase in ipairs { 'panel', 'control' } do
  test('draw callbacks stop rendering after owner teardown in the ' .. phase .. ' phase', function()
    local fixture = vrUi.boot(entries)
    withSession(fixture, function()
      local panel, instance, ended = nil, nil, false
      local laterDraws = 0
      local function endOwner(pass, visual, base)
        if (phase == 'panel' and visual.kind == 'panel') or (phase == 'control' and visual.id == 'first') then
          ended = true
          instance:disable()
        end
        base(pass, visual)
      end
      instance = owner(fixture.session, 'testing/draw-owner', function(context, service)
        panel = service:newPanel(context, options('draw-lifetime', if phase == 'panel' then endOwner else nil))
        panel:button(context, {
          id = 'first',
          bounds = { x = 0, y = 0, width = 40, height = 20 },
          onActivate = function() end,
          draw = if phase == 'control' then endOwner else nil,
        })
        panel:button(context, {
          id = 'later',
          bounds = { x = 50, y = 0, width = 40, height = 20 },
          onActivate = function() end,
          draw = function()
            laterDraws += 1
          end,
        })
      end)
      local recorder = fixture.native.events.render
      local checkpoint = recorder:checkpoint()
      panel:draw(fixture.native.events.pass)
      expect.truthy(ended, 'the selected hook ends its owner')
      expect.equal(laterDraws, 0, 'a later control does not draw after owner teardown')
      local planes = fixture:drawCalls 'plane'
      expect.equal(#planes, if phase == 'panel' then 0 else 5, 'a stale base continuation does not paint')
      recorder:assertRestored(checkpoint)
    end)
  end)
end

test('a draw callback geometry change stops the old panel transform', function()
  local fixture = vrUi.boot(entries)
  withSession(fixture, function()
    local panel
    local controlDraws = 0
    owner(fixture.session, 'testing/draw-geometry', function(context, service)
      panel = service:newPanel(
        context,
        options('draw-geometry', function(pass, visual, base)
          if visual.kind == 'panel' then
            panel:setSize(4, 2, 200, 100)
          end
          base(pass, visual)
        end)
      )
      panel:button(context, {
        id = 'stale-geometry',
        bounds = { x = 0, y = 0, width = 40, height = 20 },
        onActivate = function() end,
        draw = function()
          controlDraws += 1
        end,
      })
    end)
    local recorder = fixture.native.events.render
    local checkpoint = recorder:checkpoint()
    panel:draw(fixture.native.events.pass)
    expect.equal(panel:describe().width, 4, 'the callback commits the new geometry')
    expect.equal(controlDraws, 0, 'later controls do not use the old transform')
    expect.equal(#fixture:drawCalls 'plane', 0, 'the stale panel continuation does not paint')
    recorder:assertRestored(checkpoint)
  end)
end)

test('panel theme changes retain copied control overrides in the live provider', function()
  local fixture = vrUi.boot(entries)
  withSession(fixture, function()
    local panel, visual
    local foreground = { 0.2, 0.3, 0.4, 1 }
    owner(fixture.session, 'testing/theme-retention', function(context, service)
      panel = service:newPanel(context, options 'theme-retention')
      panel:button(context, {
        id = 'retained',
        bounds = { x = 10, y = 10, width = 40, height = 30 },
        theme = { foreground = foreground },
        onActivate = function() end,
        draw = function(_pass, value)
          visual = value
        end,
      })
    end)
    foreground[1] = 0.9
    panel:setTheme { fontSize = 23 }
    panel:draw(fixture.native.events.pass)
    expect.equal(visual.theme.foreground[1], 0.2, 'the retained control colour is detached from caller mutation')
    expect.equal(visual.theme.fontSize, 23, 'an inherited panel setting updates')
    foreground[2] = 'invalid'
    panel:setTheme { fontSize = 27 }
    panel:draw(fixture.native.events.pass)
    expect.equal(visual.theme.foreground[2], 0.3, 'an invalid caller mutation cannot change retained overrides')
    expect.equal(visual.theme.fontSize, 27, 'invalid caller data cannot prevent a panel theme change')
  end)
end)

return test

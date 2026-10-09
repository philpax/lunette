local testing = require '@testing'
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local management = require '@lunette-plugin/management'
local frameProvider = require '@lunette-plugins/frame'
local desktop = require '@lunette-desktop'
local keyboardProvider = require '@lunette-plugins/keyboard'
local ui = require '@lunette-contracts/ui'
local menu = require '@lunette-contracts/menu'
local focus = require '@lunette-contracts/focus'
local display = require '@lunette-contracts/keyboard-display'
local keyboard = require '@lunette-contracts/keyboard'
local surfaces = require '@lunette-contracts/surfaces'
local vrUi = require '@testing/vr-ui'

local fixture = {}
local active = {}

function fixture.cleanup()
  local failures = {}
  for index = #active, 1, -1 do
    local env = active[index]
    active[index] = nil
    local ok, problem = pcall(env.close, env)
    if not ok then
      failures[#failures + 1] = tostring(problem)
    end
  end
  if #failures > 0 then
    error(table.concat(failures, '; '), 0)
  end
end

function fixture.testCases(suite, failOnReports)
  return function(name, run)
    suite(name, function()
      local ok, problem = pcall(run)
      local closed, failure = pcall(fixture.cleanup)
      local failures = {}
      if not ok then
        failures[#failures + 1] = tostring(problem)
      end
      if not closed then
        local cleanupError = tostring(failure)
        if failOnReports then
          cleanupError = 'fixture cleanup: ' .. cleanupError
        elseif not ok then
          cleanupError = 'cleanup: ' .. cleanupError
        end
        failures[#failures + 1] = cleanupError
      end
      if failOnReports then
        for _, report in testing.takeReports() do
          failures[#failures + 1] = 'unexpected plugin report: ' .. tostring(report)
        end
      end
      if #failures > 0 then
        error(table.concat(failures, if failOnReports then '\n' else '; '), 0)
      end
    end)
  end
end

function fixture.boot(provider, additions, config)
  local native = testing.native()
  local services, owner = {}, nil
  local observer = plugin.define {
    name = 'manager-vr-observer',
    requires = {
      ui = ui.capability,
      menu = menu.capability,
      focus = focus.capability,
      display = display.capability,
      keyboard = keyboard.capability,
      surfaces = surfaces.capability,
    },
    init = function(context)
      owner = context
      services.ui = context:require(ui.capability)
      services.menu = context:require(menu.capability)
      services.focus = context:require(focus.capability)
      services.display = context:require(display.capability)
      services.keyboard = context:require(keyboard.capability)
      services.surfaces = context:require(surfaces.capability)
    end,
  }
  local codes = lunette.keyCodes()
  local rows = {
    {
      { label = 'Text', action = { kind = 'text', text = 'next' } },
      { label = 'Invalid', action = { kind = 'text', text = 'invalid' } },
      { label = 'Number', action = { kind = 'text', text = '13' } },
      { label = 'Failure', action = { kind = 'text', text = '99' } },
      { label = 'Map key', action = { kind = 'text', text = 'added' } },
      { label = 'All', action = { kind = 'chord', code = codes.a, modifiers = { 'control' } } },
      { label = 'Backspace', code = codes.backspace },
      { label = 'Enter', code = codes.enter },
      { label = 'Hide', action = { kind = 'hide' } },
    },
  }
  local patches = {
    { id = 'laser', config = { aim = { enabled = false }, triggerLock = { enabled = false } } },
    { id = 'desktop/manager', config = config or {} },
    { id = 'keyboard', definition = keyboardProvider.define { rows = rows, layers = {} } },
    { insert = { id = 'manager-vr-observer', definition = observer } },
  }
  if provider == 'substitute' then
    patches[#patches + 1] = { id = 'ui', definition = require('@testing/ui-substitute').definition }
  end
  for _, entry in additions or {} do
    patches[#patches + 1] = { insert = entry }
  end
  frameProvider.install { start = function() end, stop = function() end }
  local running = management.start(desktop.compose { patches = patches }, {
    protected = { 'desktop/manager', 'desktop/menu', 'desktop/actions', 'desktop/keyboard', 'desktop/pointing' },
  })
  local controls = vrUi.attach(native)
  controls:pose('left', lovr.math.newMat4():translate(0, 1.2, -0.5))
  controls:tracked('left', true)
  controls:step()
  local result = { native = native, services = services, controls = controls, running = running, owner = owner }
  function result:entry(id)
    for _, entry in self.running.service:entries() do
      if entry.id == id then
        return entry
      end
    end
    return nil
  end
  function result:open()
    self.controls:clickControl(self.services.ui, 'desktop/menu', 'open')
    self.controls:clickControl(self.services.ui, 'desktop/menu', 'actions', 'right', 'desktop/manager/open')
    self.controls:clickControl(self.services.ui, 'desktop/menu/titlebar', 'close')
    self:click 'graph-view'
  end
  function result:click(id, itemId, hand)
    self.controls:clickControl(
      self.services.ui,
      if id == 'close' then 'desktop/manager/titlebar' else 'desktop/manager',
      id,
      hand or 'right',
      itemId
    )
  end
  function result:choice(itemId)
    self:click 'choice-field'
    for _ = 1, 32 do
      local description, control = self.controls:discover(self.services.ui, 'desktop/manager', 'choice-field')
      for _, item in control.items do
        if item.id == itemId and item.bounds then
          self:click('choice-field', itemId)
          return
        end
      end
      local bounds = control.bounds
      self.controls:aim(description, bounds.x + bounds.width / 2, bounds.y + bounds.height - 12, 'right')
      self.controls:axis('right', 0, -1)
      self.controls:step()
      self.controls:axis('right', 0, 0)
      self.controls:step()
    end
    error('choice option is not reachable: ' .. itemId)
  end
  function result:row(itemId)
    for _ = 1, 32 do
      for _, control in self:description().controls do
        if control.id == 'rows' then
          for _, item in control.items do
            if item.id == itemId and item.bounds then
              self:click('rows', itemId)
              return
            end
          end
        end
      end
      self:click 'next'
    end
    error('configuration row is not reachable: ' .. itemId)
  end
  function result:description()
    for _, panel in self.services.ui:panels() do
      local description = panel:describe()
      if description.name == 'desktop/manager' then
        return description
      end
    end
    error 'manager panel is absent'
  end
  function result:key(label)
    local board
    for _, surface in self.services.surfaces:all() do
      if surface.keys and surface.setVisible then
        assert(board == nil, 'there is exactly one offered keyboard')
        board = surface
      end
    end
    assert(board, 'the shared keyboard is visible')
    board:setPose(lovr.math.newMat4():translate(0, 0.8, -0.8))
    for _, key in board:keys() do
      if key.legend == label then
        self.controls:click({
          pose = board.pose,
          width = board.width,
          height = board.height,
          logicalWidth = board.width,
          logicalHeight = board.height,
          visible = board.visible,
        }, key.x + key.width / 2, key.y + key.height / 2, 'left')
        return
      end
    end
    error('keyboard has no key ' .. label)
  end
  function result:keyboardCount()
    local count = 0
    for _, registration in self.services.keyboard:inspect().registrations do
      if registration.kind == 'keyboard' and registration.live then
        count += 1
      end
    end
    return count
  end
  function result:close()
    if self.closed then
      return
    end
    self.closed = true
    self.running.runtime:close()
    self.native.assertResourcesReleased()
  end
  active[#active + 1] = result
  return result
end

return fixture

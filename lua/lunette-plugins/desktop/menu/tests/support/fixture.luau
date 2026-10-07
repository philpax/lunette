local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local menu = require '@lunette-contracts/menu'
local vrUi = require '@testing/vr-ui'
local definition = require '@lunette-plugins/desktop/menu'

local fixture = {}

function fixture.boot(provider, config)
  config = config or {}
  local running = vrUi.boot {
    'frame',
    'surfaces',
    'drops',
    'focus',
    'interaction',
    'laser',
    'keyboard',
    'desktop/pointing',
    provider or 'ui',
    'menu',
    { id = 'desktop/menu', definition = definition, config = config },
  }
  local state = {
    running = running,
    ui = running.session:observe(ui.capability).service,
    actions = running.session:observe(menu.capability),
    hand = config.hand or 'left',
  }
  state.pointerHand = if state.hand == 'left' then 'right' else 'left'
  running:pose(state.hand, lovr.math.newMat4():translate(0, 1.2, -0.5))
  running:tracked(state.hand, true)
  running:step()
  function state:register(id, options)
    local calls = 0
    local owner
    local action = self.running.session:use(plugin.define {
      name = 'testing/action/' .. id,
      requires = { menu = menu.capability },
      init = function(context)
        owner = context
      end,
    })
    local effect = self.actions.service:register(owner, {
      id = id,
      label = options and options.label or id,
      group = options and options.group or 'Session',
      order = options and options.order or 10,
      enabled = if options then options.enabled else nil,
      selected = if options then options.selected else nil,
      run = function()
        calls += 1
        if options and options.run then
          options.run()
        end
      end,
    })
    return {
      instance = action,
      owner = owner,
      effect = effect,
      calls = function()
        return calls
      end,
    }
  end
  function state:click(id, itemId)
    self.running:clickControl(self.ui, 'desktop/menu', id, self.pointerHand, itemId)
  end
  function state:open()
    self:click 'open'
  end
  function state:description()
    return self.ui:panels()[1]:describe()
  end
  function state:press(id, itemId)
    local description, control = self.running:discover(self.ui, 'desktop/menu', id, itemId)
    local bounds = assert(control.bounds)
    self.running:button(self.pointerHand, 'trigger', false)
    self.running:aim(description, bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, self.pointerHand)
    self.running:step()
    self.running:button(self.pointerHand, 'trigger', true)
    self.running:step()
  end
  function state:release()
    self.running:button(self.pointerHand, 'trigger', false)
    self.running:step()
  end
  function state:scroll(delta)
    local description, control = self.running:discover(self.ui, 'desktop/menu', 'actions')
    local bounds = assert(control.bounds)
    self.running:aim(description, bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, self.pointerHand)
    self.running:axis(self.pointerHand, 0, delta)
    self.running:step(0.1)
    self.running:axis(self.pointerHand, 0, 0)
  end
  return state
end

return fixture

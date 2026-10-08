local testing = require '@testing'
local plugin = require '@lunette-plugin'
local management = require '@lunette-plugin/management'
local frame = require '@lunette-plugins/frame'
local surfaces = require '@lunette-plugins/surfaces'
local focus = require '@lunette-plugins/focus'
local ui = require '@lunette-plugins/ui'
local menu = require '@lunette-plugins/menu'
local drops = require '@lunette-plugins/drops'
local interaction = require '@lunette-plugins/interaction'
local surfaceContract = require '@lunette-contracts/surfaces'
local menuContract = require '@lunette-contracts/menu'
local uiContract = require '@lunette-contracts/ui'
local focusContract = require '@lunette-contracts/focus'
local interactionContract = require '@lunette-contracts/interaction'
local manager = require '@lunette-plugins/desktop/manager'
local controller = require '@lunette-plugins/desktop/manager/controller'

return function(config, additions, protected)
  config = table.clone(config or {})
  if config.view == nil then
    config.view = 'graph'
  end
  local fake = testing.native()
  local font = {
    getHeight = function()
      return 1
    end,
    getLineSpacing = function()
      return 1
    end,
    getWidth = function(_, text)
      return #text * 0.5
    end,
    getLines = function(_, text)
      local result = {}
      for line in (text .. '\n'):gmatch '(.-)\n' do
        result[#result + 1] = line
      end
      return result
    end,
  }
  lovr.graphics.getDefaultFont = function()
    return font
  end
  for _, name in
    {
      'push',
      'pop',
      'transform',
      'translate',
      'scale',
      'setShader',
      'setMaterial',
      'setFont',
      'setCullMode',
      'setDepthTest',
      'setDepthWrite',
    }
  do
    fake.events.pass[name] = function(_, ...)
      fake.events.draw[#fake.events.draw + 1] = { name, ... }
    end
  end
  local surfaceService, menuService, uiService, focusService, pointerService, owner
  local observed = plugin.define {
    name = 'surface-observer',
    requires = {
      surfaces = surfaceContract.capability,
      menu = menuContract.capability,
      ui = uiContract.capability,
      focus = focusContract.capability,
      interaction = interactionContract.capability,
    },
    init = function(context)
      owner = context
      surfaceService = context:require(surfaceContract.capability)
      menuService = context:require(menuContract.capability)
      uiService = context:require(uiContract.capability)
      focusService = context:require(focusContract.capability)
      pointerService = context:require(interactionContract.capability)
    end,
  }
  frame.install { start = function() end, stop = function() end }
  local entries = {
    { id = 'theme', definition = require('@lunette-plugins/theme').definition },
    { id = 'frame', definition = frame.definition },
    { id = 'surfaces', definition = surfaces.definition },
    { id = 'focus', definition = focus.definition },
    { id = 'ui', definition = ui.definition },
    { id = 'menu', definition = menu.definition },
    { id = 'drops', definition = drops.definition },
    { id = 'interaction', definition = interaction.definition },
    { id = 'desktop/manager', definition = manager, config = config or {} },
    { id = 'observer', definition = observed },
  }
  for _, entry in additions or {} do
    local replaced = false
    for index, present in entries do
      if present.id == entry.id then
        entries[index], replaced = entry, true
        break
      end
    end
    if not replaced then
      entries[#entries + 1] = entry
    end
  end
  local state
  local new = controller.new
  controller.new = function(...)
    state = new(...)
    return state
  end
  local ok, running = pcall(management.start, entries, { protected = protected or { 'desktop/manager' } })
  controller.new = new
  if not ok then
    error(running, 0)
  end
  local public = { ui = uiService, focus = focusService }
  function public:panel()
    for _, panel in self.ui:panels() do
      if panel:describe().name == 'desktop/manager' then
        return panel
      end
    end
    error('the manager has no public UI panel', 0)
  end
  function public:control(id)
    if id == 'Close' then
      id = 'close'
    end
    for _, panel in self.ui:panels() do
      local description = panel:describe()
      if description.name == 'desktop/manager' or description.name == 'desktop/manager/titlebar' then
        for _, control in description.controls do
          if control.id == id or control.label == id then
            return control, description
          end
        end
      end
    end
    error('the manager has no public control ' .. id, 0)
  end
  function public:point(id, itemId)
    local control, description = self:control(id)
    local bounds = control.bounds
    if itemId then
      bounds = nil
      for _, item in control.items do
        if item.id == itemId or item.label == itemId then
          bounds = item.bounds
          break
        end
      end
    end
    assert(bounds, 'the public control or item has no visible geometry')
    local x, y = bounds.x + bounds.width / 2, bounds.y + bounds.height / 2
    if description.name ~= 'desktop/manager' then
      local world = lovr.math.newMat4(table.unpack(description.pose))
      local body = self:panel():describe()
      local px, py, pz = world:mul(
        (x / description.logicalWidth - 0.5) * description.width,
        (0.5 - y / description.logicalHeight) * description.height,
        0,
        1
      )
      local lx, ly = lovr.math.newMat4(table.unpack(body.pose)):invert():mul(px, py, pz, 1)
      x, y = (lx / body.width + 0.5) * body.logicalWidth, (0.5 - ly / body.height) * body.logicalHeight
    end
    return x, y
  end
  function public:pointer()
    return pointerService:newPointer(owner, { tuning = { scrollScale = 36 } })
  end
  function public:source()
    return focusService:newSource(owner)
  end
  function public:update(pointer, x, y, fields)
    fields = fields or {}
    local offered = surfaceService:all()[1]
    local description = self:panel():describe()
    assert(offered, 'the manager is not visible')
    pointer:update({
      origin = vector.pack(
        offered.pose:mul(
          (x / description.logicalWidth - 0.5) * offered.width,
          (0.5 - y / description.logicalHeight) * offered.height,
          1,
          1
        )
      ),
      direction = fields.direction or vector.pack(offered.pose:mul(0, 0, -1, 0)),
      pose = fields.pose or lovr.math.newMat4(),
      buttons = fields.buttons or {},
      grip = fields.grip or false,
      scrollX = fields.scrollX,
      scrollY = fields.scrollY,
      dt = fields.dt or 1,
    }, surfaceService:all())
  end
  function public:click(pointer, id, itemId)
    local x, y = self:point(id, itemId)
    self:update(pointer, x, y, { buttons = { left = true } })
    self:update(pointer, x, y)
  end
  function public:open()
    assert(menuService:invoke('desktop/manager/open').kind == 'invoked', 'the public menu action is unavailable')
    return self:panel()
  end
  return running, fake, function()
    return surfaceService:all()
  end, state, menuService, public
end

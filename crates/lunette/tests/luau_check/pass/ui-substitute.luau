--!strict
-- Structural substitution is checked without importing the unchecked test-scaffolding root.

local ui = require '@lunette-contracts/ui'
local surface = require '@lunette-contracts/surface'

local ownerIdentity: ui.OwnerIdentity = { kind = 'ui-owner' }
table.freeze(ownerIdentity)

local function control(id: string): ui.Control
  return {
    dead = false,
    id = id,
    owner = ownerIdentity,
    setBounds = function(_: ui.Control, _: ui.Bounds) end,
    setEnabled = function(_: ui.Control, _: boolean) end,
    setTheme = function(_: ui.Control, _: ui.ThemeOverrides?) end,
    destroy = function(_: ui.Control): boolean
      return true
    end,
  }
end

local function textField(id: string): ui.TextField
  local base = control(id)
  return {
    dead = base.dead,
    id = base.id,
    owner = base.owner,
    setBounds = base.setBounds,
    setEnabled = base.setEnabled,
    setTheme = base.setTheme,
    destroy = base.destroy,
    setValue = function(_: ui.TextField, _: string) end,
    value = function(_: ui.TextField): string
      return ''
    end,
    setSelection = function(_: ui.TextField, _: number, _: number?) end,
    selection = function(_: ui.TextField): (number, number)
      return 1, 1
    end,
    setError = function(_: ui.TextField, _: string?) end,
    focus = function(_: ui.TextField): boolean
      return true
    end,
    blur = function(_: ui.TextField): boolean
      return true
    end,
  }
end

local function choice(id: string): ui.Choice
  local base = control(id)
  return {
    dead = base.dead,
    id = base.id,
    owner = base.owner,
    setBounds = base.setBounds,
    setEnabled = base.setEnabled,
    setTheme = base.setTheme,
    destroy = base.destroy,
    setItems = function(_: ui.Choice, _: { read [number]: ui.Item }) end,
    setSelected = function(_: ui.Choice, _: string?) end,
    selected = function(_: ui.Choice): string?
      return nil
    end,
    setOpen = function(_: ui.Choice, _: boolean) end,
    scroll = function(_: ui.Choice, _: number) end,
  }
end

local function list(id: string): ui.List
  local base = control(id)
  return {
    dead = base.dead,
    id = base.id,
    owner = base.owner,
    setBounds = base.setBounds,
    setEnabled = base.setEnabled,
    setTheme = base.setTheme,
    destroy = base.destroy,
    setItems = function(_: ui.List, _: { read [number]: ui.Item }) end,
    setSelected = function(_: ui.List, _: string?) end,
    selected = function(_: ui.List): string?
      return nil
    end,
    scroll = function(_: ui.List, _: number) end,
  }
end

local function region(id: string): ui.Region
  local base = control(id)
  return {
    dead = base.dead,
    id = base.id,
    owner = base.owner,
    setBounds = base.setBounds,
    setEnabled = base.setEnabled,
    setTheme = base.setTheme,
    destroy = base.destroy,
    setItems = function(_: ui.Region, _: { read [number]: ui.RegionItem }) end,
  }
end

local generation: ui.Generation = { kind = 'ui-generation' }
table.freeze(generation)

local function panel(options: ui.PanelOptions): ui.Panel
  local pose = if options.pose then lovr.math.newMat4(options.pose) else lovr.math.newMat4()
  local description: ui.Description = {
    name = options.name,
    generation = generation,
    revision = 1,
    pose = { pose:unpack(true) },
    width = options.width,
    height = options.height,
    logicalWidth = options.logicalWidth,
    logicalHeight = options.logicalHeight,
    visible = options.visible ~= false,
    controls = {},
  }
  return {
    dead = false,
    setPose = function(_: ui.Panel, _: Mat4) end,
    setSize = function(_: ui.Panel, _: number, _: number, _: number?, _: number?) end,
    setVisible = function(_: ui.Panel, _: boolean) end,
    setTheme = function(_: ui.Panel, _: ui.ThemeOverrides?) end,
    setTitlebar = function(_: ui.Panel, _: ui.TitlebarOptions?) end,
    draw = function(_: ui.Panel, _: Pass) end,
    describe = function(_: ui.Panel): ui.Description
      return description
    end,
    destroy = function(_: ui.Panel): boolean
      return true
    end,
    button = function(_: ui.Panel, _: ui.Owner, value: ui.ButtonOptions): ui.Button
      return control(value.id)
    end,
    textField = function(_: ui.Panel, _: ui.Owner, value: ui.TextFieldOptions): ui.TextField
      return textField(value.id)
    end,
    choice = function(_: ui.Panel, _: ui.Owner, value: ui.ChoiceOptions): ui.Choice
      return choice(value.id)
    end,
    list = function(_: ui.Panel, _: ui.Owner, value: ui.ListOptions): ui.List
      return list(value.id)
    end,
    region = function(_: ui.Panel, _: ui.Owner, value: ui.RegionOptions): ui.Region
      return region(value.id)
    end,
  }
end

local independentlyTypedService = {
  newPanel = function(_: ui.Service, _: ui.Owner, options: ui.PanelOptions): ui.Panel
    return panel(options)
  end,
  newTitlebar = function(
    _: ui.Service,
    _: ui.Owner,
    _: string,
    _: surface.Surface,
    _: ui.TitlebarOptions,
    _: (() -> boolean)?
  ): ui.Titlebar
    return {
      dead = false,
      update = function(_: ui.Titlebar, _: ui.TitlebarOptions) end,
      sync = function(_: ui.Titlebar) end,
      draw = function(_: ui.Titlebar, _: Pass) end,
      destroy = function(_: ui.Titlebar): boolean
        return true
      end,
    }
  end,
  panels = function(_: ui.Service): { ui.Panel }
    return {}
  end,
}
local service: ui.Service = independentlyTypedService

local function describeControl(value: ui.Control): ui.ControlDescription
  return {
    id = value.id,
    owner = value.owner,
    kind = 'button',
    label = 'Button',
    enabled = true,
    items = {},
  }
end

local function consume(owner: ui.Owner)
  local handle = service:newPanel(owner, {
    name = 'Typed substitute',
    width = 1,
    height = 1,
    logicalWidth = 100,
    logicalHeight = 100,
  })
  local button: ui.Button = handle:button(owner, {
    id = 'button',
    bounds = { x = 0, y = 0, width = 20, height = 20 },
    onActivate = function() end,
  })
  local identity: ui.OwnerIdentity = button.owner
  local metadata: ui.ControlDescription = describeControl(button)
  assert(identity == ownerIdentity and identity == metadata.owner and identity.kind == 'ui-owner')
  button:setEnabled(true)
  local field: ui.TextField = handle:textField(owner, {
    id = 'field',
    bounds = { x = 20, y = 0, width = 40, height = 20 },
    value = 'draft',
  })
  field:setSelection(1)
  field:focus()
  local selected: ui.Choice = handle:choice(owner, {
    id = 'choice',
    bounds = { x = 0, y = 20, width = 40, height = 60 },
    items = { { id = 'stable', label = 'Stable' } },
    onChange = function(_: string) end,
  })
  selected:setOpen(true)
  local rows: ui.List = handle:list(owner, {
    id = 'list',
    bounds = { x = 40, y = 20, width = 40, height = 60 },
    items = {},
  })
  rows:scroll(20)
  local custom: ui.Region = handle:region(owner, {
    id = 'custom',
    bounds = { x = 0, y = 80, width = 100, height = 20 },
  })
  custom:setItems {}
  return handle:describe()
end

return { service = service, consume = consume }

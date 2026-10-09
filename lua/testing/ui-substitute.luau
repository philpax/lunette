-- Independent contract-test UI composes owner-scoped panels through public services.

local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local focus = require '@lunette-contracts/focus'
local theme = require '@lunette-contracts/theme'
local frame = require '@lunette-contracts/frame'
local appearance = require './ui-substitute/appearance'
local surfaces = require '@lunette-contracts/surfaces'
local panels = require './ui-substitute/panels'
local ownerRegistry = require './ui-substitute/owner-registry'
local titlebar = require '@lunette-plugins/ui/titlebar'
local surfaceGeometry = require './ui-substitute/surface-geometry'

local substitute = {}
substitute.requires = {
  focus = focus.capability,
  surfaces = surfaces.capability,
  theme = theme.capability,
  frame = frame.capability,
}

function substitute.build(context: plugin.Context, settings): ui.Service
  settings = settings or {}
  local overrides = appearance.copyOverrides(settings.theme)
  local state = {
    context = context,
    focus = context:require(focus.capability),
    theme = context:require(theme.capability),
    panels = {},
    draw = settings.draw,
    overrides = overrides or {},
    owners = ownerRegistry.new(context),
    generation = table.freeze { kind = 'ui-generation' },
  }
  local titlebars = {}
  local callerThemes = setmetatable({}, { __index = state.theme })
  function callerThemes.acquireFont(_, owner, spec)
    local lease, effect = context:resource(owner, function()
      local acquired = state.theme:acquireFont(context, spec)
      return acquired, function()
        acquired:dispose()
      end
    end)
    return {
      font = lease.font,
      spec = lease.spec,
      withFont = function(_, run)
        lease:withFont(run)
      end,
      dispose = function()
        effect:dispose()
      end,
    }
  end
  local initial = state.theme:current()
  local revision = initial.revision
  state.base = appearance.theme(appearance.global(initial), overrides)
  state.radius = initial.theme.radii.uiPanel
  function state.refreshBase()
    if not context:active() then
      return
    end
    local current = state.theme:current()
    if current.revision ~= revision then
      state.base = appearance.theme(appearance.global(current), overrides)
      state.radius = current.theme.radii.uiPanel
      revision = current.revision
    end
  end
  state.theme:onChanged(context, function(_snapshot)
    if not context:active() then
      return
    end
    state.refreshBase()
    for _, current in table.clone(titlebars) do
      if not current.dead then
        current:sync()
      end
    end
    for _, panel in table.clone(state.panels) do
      if panel.live() then
        panel.refresh()
      end
    end
  end)
  context:require(frame.capability):onUpdate(context, {
    phase = 'scene',
    order = 1000,
    run = function()
      for _, current in table.clone(titlebars) do
        if not current.dead then
          current:sync()
        end
      end
    end,
  })
  local offers = context:require(surfaces.capability)
  local service = {}
  function state.decorate(owner, name, target, options, visible)
    return service:newTitlebar(owner, name, target, options, visible)
  end
  function service.newTitlebar(_, owner, name, target, options, visible)
    local created = nil
    local result = titlebar.new(
      context,
      owner,
      name,
      target,
      options,
      visible,
      service,
      offers,
      {},
      callerThemes,
      function(handle, contour)
        for _, panel in state.panels do
          if panel.handle == handle and panel.live() then
            surfaceGeometry.contour(panel, contour)
            return
          end
        end
      end,
      function()
        if created then
          local index = table.find(titlebars, created)
          if index then
            table.remove(titlebars, index)
          end
          created = nil
        end
      end
    )
    created = result
    if not result.dead then
      titlebars[#titlebars + 1] = result
    end
    return result
  end
  function service.newPanel(_: ui.Service, owner: ui.Owner, options: ui.PanelOptions): ui.Panel
    context:checkOwner(owner)
    return panels.new(state, owner, options)
  end
  function service.panels(_: ui.Service): { ui.Panel }
    local result = {}
    for _, panel in state.panels do
      if panel.live() then
        result[#result + 1] = panel.handle
      end
    end
    return table.freeze(result)
  end
  context:require(surfaces.capability):offer(context, {
    name = 'testing/ui-substitute',
    list = function()
      local result = {}
      for _, panel in state.panels do
        if panel.live() and panel.visible then
          result[#result + 1] = panel.surface
        end
      end
      return result
    end,
  })
  return service
end

substitute.definition = plugin.define {
  name = 'testing/ui-substitute',
  requires = substitute.requires,
  provides = { ui = ui.capability },
  init = function(context, _, provide)
    provide:provide(ui.capability, substitute.build(context))
  end,
}

return substitute

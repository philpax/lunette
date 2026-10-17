-- A menu action that opens and closes something its owner shows, such as a panel or a mirror. The action's selection
-- follows whether it is open, and opening or closing saves that through the owner's entry, so it opens at the next
-- start as it was left. The owner supplies how to show and hide; a close from elsewhere, such as a panel's close
-- button, goes through `set` so the menu and the saved state follow.
local plugin = require '@lunette-plugin'
local menu = require '@lunette-contracts/menu'

local toggle = {}

export type Options = {
  read id: string,
  read label: string,
  read group: string?,
  read order: number?,
  -- Whether it opens at start, from the entry's settings.
  read visible: boolean,
  -- Shows it. `requested` is true when the user asked through the menu, and false when it opens at start.
  read show: (requested: boolean) -> (),
  read hide: () -> (),
  -- Saves whether it is open. Without one, the owner's context saves `visible`.
  read save: ((boolean) -> ())?,
}

export type Toggle = {
  read set: (Toggle, boolean) -> (),
  read open: (Toggle) -> boolean,
  -- Removes the action, leaving what it shows as it is, such as when the thing it opens is gone.
  read dispose: (Toggle) -> (),
}

function toggle.attach(context: plugin.Context, menus: menu.Service, options: Options): Toggle
  local open, saved = false, options.visible
  local registration: menu.Registration? = nil
  local save = options.save or function(visible: boolean): ()
    context:save { visible = visible }
  end
  local function change(show: boolean, requested: boolean): ()
    if show == open then
      return
    end
    open = show
    if show then
      options.show(requested)
    else
      options.hide()
    end
    if registration then
      registration:update { selected = show }
    end
    if show ~= saved then
      saved = show
      save(show)
    end
  end
  if options.visible then
    change(true, false)
  end
  registration = menus:register(context, {
    id = options.id,
    label = options.label,
    group = options.group,
    order = options.order,
    selected = open,
    run = function(): ()
      change(not open, true)
    end,
  })
  return table.freeze {
    set = function(_self: Toggle, show: boolean): ()
      change(show, false)
    end,
    open = function(_self: Toggle): boolean
      return open
    end,
    dispose = function(_self: Toggle): ()
      local held = registration
      registration = nil
      if held then
        held:dispose()
      end
    end,
  }
end

return toggle

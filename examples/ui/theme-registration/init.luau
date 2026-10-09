-- An opt-in manual theme lifecycle demonstration uses public services and child-instance ownership.
local plugin = require '@lunette-plugin'
local schema = require '@lunette-plugin/schema'
local theme = require '@lunette-contracts/theme'
local ui = require '@lunette-contracts/ui'
local menu = require '@lunette-contracts/menu'
local frame = require '@lunette-contracts/frame'
local session = require '@self/session'
local selections = require '@self/selections'
local fonts = require '@self/fonts'

local descriptor = schema.object {
  enabled = schema.default(schema.boolean())(false),
}
export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return plugin.consumer<<Config, Settings>>({
  name = 'example/ui/theme-registration',
  requires = { theme = theme.capability, ui = ui.capability, menu = menu.capability, frame = frame.capability },
  schema = descriptor,
  init = function(context: plugin.Context, settings: Settings): ()
    if not settings.enabled then
      return
    end
    local themes: theme.Service = context:require(theme.capability)
    local widgets: ui.Service = context:require(ui.capability)
    local actions: menu.Service = context:require(menu.capability)
    local frames: frame.Service = context:require(frame.capability)
    local demo = session.new(context, themes)
    selections.install(demo)
    fonts.install(demo, widgets, frames)
    local panel = widgets:newPanel(context, {
      name = 'example/ui/theme-registration',
      pose = lovr.math.newMat4():translate(vector.pack(-0.25, 1.4, -1.5)),
      width = 1.15,
      height = 0.92,
      logicalWidth = 900,
      logicalHeight = 720,
      visible = false,
      grabbable = true,
      theme = { fontSize = 17, rowHeight = 34 },
    })
    local selected = demo.actions[1].id
    local items: { ui.Item } = {}
    local byId: { [string]: session.Action } = {}
    for order, action in demo.actions do
      items[order] = { id = action.id, label = action.label }
      byId[action.id] = action
      actions:register(context, {
        id = 'example/ui/theme-registration/' .. action.id,
        label = action.label,
        group = 'Theme lifecycle',
        order = order,
        run = action.run,
      })
    end
    panel:list(context, {
      id = 'actions',
      label = 'Select action; scroll, then run',
      bounds = { x = 16, y = 64, width = 366, height = 636 },
      items = items,
      selected = selected,
      onChange = function(id: string): ()
        selected = id
      end,
    })
    panel:button(context, {
      id = 'run',
      label = 'Run selected action',
      bounds = { x = 16, y = 16, width = 280, height = 36 },
      onActivate = function(): ()
        -- Menu invocation gives UI buttons the same owner-protected reporting boundary as wrist actions.
        actions:invoke('example/ui/theme-registration/' .. assert(byId[selected]).id)
      end,
    })
    panel:button(context, {
      id = 'close',
      label = 'Close observation',
      bounds = { x = 664, y = 16, width = 220, height = 36 },
      onActivate = function(): ()
        if context:active() and not panel.dead then
          panel:setVisible(false)
        end
      end,
    })
    panel:region(context, {
      id = 'observations',
      label = 'Live observations',
      bounds = { x = 398, y = 64, width = 486, height = 636 },
      draw = function(pass: Pass, visual: ui.Visual, base: ui.Renderer): ()
        base(pass, visual)
        local clip: ui.Bounds = visual.clip
        if clip.width <= 16 or clip.height <= 16 then
          return
        end
        local font: Font = visual.theme.font
        local height: number = font:getHeight()
        local preferred = 17 / height
        local wrapped: { string } = {}
        for line in (demo.report() .. '\n'):gmatch '(.-)\n' do
          local current = ''
          for word in line:gmatch '%S+' do
            local candidate = if current == '' then word else current .. ' ' .. word
            if current ~= '' and font:getWidth(candidate) * preferred > clip.width - 16 then
              table.insert(wrapped, current)
              current = word
            else
              current = candidate
            end
          end
          table.insert(wrapped, current)
        end
        local report = table.concat(wrapped, '\n')
        pass:setFont(font)
        local scale: number = math.min(
          preferred,
          (clip.width - 16) / math.max(font:getWidth(report), 1),
          (clip.height - 16) / (#wrapped * height)
        )
        pass:setColor(visual.theme.foreground)
        -- Logical panel coordinates are y-down, while text glyphs are y-up.
        pass:text(report, clip.x + 8, clip.y + 8, 0, scale, math.pi, 1, 0, 0, 0, 'left', 'top')
      end,
    })
    actions:register(context, {
      id = 'example/ui/theme-registration/open',
      label = 'Open theme lifecycle observation',
      group = 'Examples',
      order = 5,
      run = function(): ()
        if context:active() and not panel.dead then
          panel:setVisible(true)
        end
      end,
    })
    frames:onDraw(context, {
      phase = 'overlay',
      run = function(pass: Pass): ()
        if context:active() and not panel.dead then
          panel:draw(pass)
        end
      end,
    })
  end,
}).definition

-- A third-party form uses the configured UI provider and the desktop's shared keyboard.
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local menu = require '@lunette-contracts/menu'
local frame = require '@lunette-contracts/frame'
local vocabulary = require '@lunette-contracts/vocabulary'

export type Config = {}
export type Settings = {}

return plugin.consumer<<Config, Settings>>({
  name = 'example/ui/form',
  requires = { ui.capability, menu.capability, frame.capability },
  init = function(context: plugin.Context, _settings: Settings)
    local widgets: ui.Service = context:require(ui.capability)
    local actions: menu.Service = context:require(menu.capability)
    local frames: frame.Service = context:require(frame.capability)
    local panel = widgets:newPanel(context, {
      name = 'example/ui/form',
      pose = lovr.math.newMat4():translate(vector.pack(0, 1.4, -1.4)),
      width = 0.9,
      height = 0.84,
      logicalWidth = 600,
      logicalHeight = 560,
      visible = false,
      grabbable = true,
      theme = { fontSize = 18, rowHeight = 32 },
    })
    local presses, taps, cancelled = 0, 0, 0
    local text, mode, destination = '', 'quiet', 'destination-1'
    local held: { [vocabulary.Pointer]: boolean } = {}

    panel:button {
      id = 'press',
      label = 'Count a press',
      bounds = { x = 24, y = 28, width = 250, height = 44 },
      onActivate = function()
        presses += 1
      end,
    }
    panel:textField {
      id = 'name',
      label = 'Name',
      bounds = { x = 24, y = 96, width = 552, height = 48 },
      value = text,
      onChange = function(value: string)
        text = value
      end,
    }
    panel:choice {
      id = 'mode',
      label = 'Mode',
      bounds = { x = 24, y = 172, width = 250, height = 172 },
      items = {
        { id = 'quiet', label = 'Quiet' },
        { id = 'studio', label = 'Studio' },
        { id = 'outdoors', label = 'Outdoors' },
      },
      selected = mode,
      onChange = function(value: string)
        mode = value
      end,
    }
    local destinations: { ui.Item } = {}
    for index = 1, 24 do
      destinations[index] = { id = 'destination-' .. tostring(index), label = 'Destination ' .. tostring(index) }
    end
    panel:list {
      id = 'destinations',
      label = 'Destinations: scroll with the thumbstick',
      bounds = { x = 298, y = 172, width = 278, height = 220 },
      items = destinations,
      selected = destination,
      onChange = function(value: string)
        destination = value
      end,
    }
    panel:region {
      id = 'preview',
      label = 'Live preview: tap to count',
      bounds = { x = 24, y = 412, width = 552, height = 124 },
      onPointer = function(event: vocabulary.PointerEvent)
        if event.kind == 'press' then
          if event.button == 'left' then
            held[event.pointer] = true
          end
        elseif event.kind == 'cancel' then
          if event.button == 'left' and held[event.pointer] then
            held[event.pointer] = nil
            cancelled += 1
          end
        elseif event.kind == 'release' then
          if event.button == 'left' and held[event.pointer] then
            held[event.pointer] = nil
            if event.inside then
              taps += 1
            end
          end
        end
      end,
      draw = function(pass: Pass, visual: ui.Visual, base: ui.Renderer)
        base(pass, visual)
        local clip = visual.clip
        if clip.width <= 16 or clip.height <= 16 then
          return
        end
        local report = 'Presses: '
          .. tostring(presses)
          .. '; name: '
          .. text:gsub('[%z\1-\31\127]', ' ')
          .. ';\nmode: '
          .. mode
          .. '; destination: '
          .. destination
          .. ';\ntaps: '
          .. tostring(taps)
          .. '; cancelled: '
          .. tostring(cancelled)
          .. ';'
        local font = lovr.graphics.getDefaultFont()
        pass:setFont(font)
        local scale = math.min(18 / font:getHeight(), (clip.width - 16) / math.max(font:getWidth(report), 1))
        scale = math.min(scale, (clip.height - 16) / (3 * font:getHeight()))
        pass:setColor(0.65, 0.9, 1, 1)
        -- Logical panel coordinates are y-down, while text glyphs are y-up.
        pass:text(report, clip.x + 8, clip.y + 8, 0, scale, math.pi, 1, 0, 0, 0, 'left', 'top')
      end,
    }
    panel:button {
      id = 'close',
      label = 'Close',
      bounds = { x = 444, y = 28, width = 132, height = 44 },
      onActivate = function()
        if context:active() and not panel.dead then
          -- Hiding ends field focus and pointer captures without claiming another owner's route.
          panel:setVisible(false)
        end
      end,
    }
    actions:register(context, {
      id = 'example/ui/open',
      label = 'Open example form',
      group = 'Examples',
      order = 4,
      run = function()
        if context:active() and not panel.dead then
          panel:setVisible(true)
        end
      end,
    })
    frames:onDraw(context, {
      phase = 'overlay',
      run = function(pass: Pass)
        if context:active() and not panel.dead then
          panel:draw(pass)
        end
      end,
    })
  end,
}).definition

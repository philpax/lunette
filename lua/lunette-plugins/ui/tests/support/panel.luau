local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local ui = require '@lunette-contracts/ui'
local frame = require '@lunette-contracts/frame'
local keyboard = require '@lunette-contracts/keyboard'
local surfaces = require '@lunette-contracts/surfaces'
local focus = require '@lunette-contracts/focus'
local theme = require '@lunette-contracts/theme'
local vrUi = require '@testing/vr-ui'

export type Bounds = ui.Bounds
export type PointerEvent = ui.PointerEvent

type Options = { keyboard: boolean?, theme: ui.ThemeOverrides?, draw: ui.DrawHook? }
export type Event = {
  read kind: 'enter' | 'leave' | 'move' | 'press' | 'release' | 'scroll' | 'cancel',
  read reason: ui.CancelReason?,
}
export type State = {
  fixture: vrUi.Fixture,
  activations: { boolean },
  submits: { string },
  cancels: { string },
  events: { Event },
  instance: adapter.Instance<{}>?,
  owner: adapter.Context?,
  themes: theme.Service?,
  service: ui.Service?,
  panel: ui.Panel?,
  button: ui.Button?,
  field: ui.TextField?,
  choice: ui.Choice?,
  list: ui.List?,
  region: ui.Region?,
  chosen: string?,
  listed: string?,
  board: keyboard.Keyboard?,
  focus: typeof(vrUi.boot({}).session:observe(focus.capability))?,
}

local fixture = {}

local ROWS = {
  {
    { code = 30, label = 'A' },
    { code = 14, label = 'Backspace' },
    { code = 28, label = 'Submit' },
    { code = 1, label = 'Cancel' },
    { action = { kind = 'text', text = 'é👩🏽‍💻' }, label = 'Cluster' },
  },
}

function fixture.boot(options: Options?): State
  options = options or {}
  local running = vrUi.boot {
    'theme',
    'frame',
    'surfaces',
    'drops',
    'focus',
    'interaction',
    {
      id = 'laser',
      definition = require('@lunette-plugins/laser').definition,
      config = { aim = { enabled = false }, triggerLock = { enabled = false } },
    },
    {
      id = 'keyboard',
      definition = require('@lunette-plugins/keyboard').definition,
      config = { rows = ROWS },
    },
    'desktop/pointing',
    'ui',
  }
  local state: State = { fixture = running, activations = {}, submits = {}, cancels = {}, events = {} }
  state.instance = running.session:use(adapter.define {
    name = 'testing/public-ui-form',
    requires = {
      ui.capability,
      frame.capability,
      keyboard.capability,
      surfaces.capability,
      theme.capability,
    },
    init = function(context: adapter.Context)
      state.owner = context
      state.themes = context:require(theme.capability)
      state.service = context:require(ui.capability)
      local panel = state.service:newPanel(context, {
        name = 'public-ui-form',
        pose = lovr.math.newMat4():translate(0, 1.5, -2):rotate(0.2, 0, 1, 0),
        width = 2,
        height = 1.5,
        logicalWidth = 400,
        logicalHeight = 300,
        theme = options.theme,
      })
      state.panel = panel
      state.button = panel:button {
        id = 'run',
        label = 'Run',
        bounds = { x = 10, y = 10, width = 80, height = 40 },
        draw = options.draw,
        onActivate = function()
          state.activations[#state.activations + 1] = true
        end,
      }
      state.field = panel:textField {
        id = 'draft',
        label = 'Draft',
        bounds = { x = 110, y = 10, width = 270, height = 40 },
        draw = options.draw,
        value = '',
        onSubmit = function(value: string)
          state.submits[#state.submits + 1] = value
        end,
        onCancel = function(value: string)
          state.cancels[#state.cancels + 1] = value
        end,
      }
      local items: { ui.Item } = {}
      for index = 1, 20 do
        items[index] = { id = 'item-' .. index, label = 'Item ' .. index, enabled = index ~= 2 }
      end
      state.choice = panel:choice {
        id = 'choice',
        label = 'Choice',
        bounds = { x = 10, y = 70, width = 180, height = 180 },
        items = items,
        onChange = function(value: string)
          state.chosen = value
        end,
      }
      state.list = panel:list {
        id = 'list',
        label = 'List',
        bounds = { x = 210, y = 70, width = 170, height = 180 },
        items = items,
        onChange = function(value: string)
          state.listed = value
        end,
      }
      state.region = panel:region {
        id = 'custom',
        label = 'Custom',
        bounds = { x = 10, y = 260, width = 370, height = 30 },
        items = {
          {
            id = 'node',
            label = 'Node',
            bounds = { x = 20, y = 265, width = 20, height = 20 },
            route = { { x = 20, y = 265 }, { x = 40, y = 285 } },
          },
        },
        onPointer = function(event: ui.PointerEvent)
          state.events[#state.events + 1] = event
        end,
      }
      context:require(frame.capability):onDraw(context, {
        phase = 'scene',
        run = function(pass: Pass)
          panel:draw(pass)
        end,
      })
      if options.keyboard then
        local board = context:require(keyboard.capability):new(context, {
          rows = ROWS,
          layers = {},
          pose = lovr.math.newMat4():translate(0, 0.5, -1),
        })
        state.board = board
        context:require(surfaces.capability):offer(context, {
          name = 'public-ui-form-keyboard',
          list = function(): { keyboard.Keyboard }
            return if board.visible then { board } else {}
          end,
        })
        context:require(frame.capability):onDraw(context, {
          phase = 'scene',
          run = function(pass: Pass)
            board:draw(pass)
          end,
        })
      end
    end,
  })
  state.focus = running.session:observe(focus.capability)
  return state
end

function fixture.press(state: State, id: string, hand: vrUi.Hand?, itemId: string?)
  hand = hand or 'right'
  local description, control = state.fixture:discover(state.service, 'public-ui-form', id, itemId)
  local bounds = assert(control.bounds)
  state.fixture:button(hand, 'trigger', false)
  state.fixture:aim(description, bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, hand)
  state.fixture:step()
  state.fixture:button(hand, 'trigger', true)
  state.fixture:step()
end

function fixture.scroll(state: State, id: string, y: number, hand: vrUi.Hand?)
  hand = hand or 'right'
  local description, control = state.fixture:discover(state.service, 'public-ui-form', id)
  local bounds = assert(control.bounds)
  state.fixture:aim(description, bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, hand)
  state.fixture:axis(hand, 0, y)
  state.fixture:step(0.1)
  state.fixture:axis(hand, 0, 0)
end

function fixture.key(state: State, index: number, hand: vrUi.Hand?)
  local board = state.board
  local description = {
    visible = board.visible,
    pose = { board.pose:unpack(true) },
    width = board.width,
    height = board.height,
    logicalWidth = 5,
    logicalHeight = 1,
  }
  state.fixture:click(description, index - 0.5, 0.5, hand)
end

return fixture

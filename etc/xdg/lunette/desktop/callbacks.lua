-- LÖVR callbacks dispatched only to active configuration scopes.
local plugin = require '@lunette-plugin'
local surface = require '@lunette-contracts/surface'
local logging = require '../desktop/logging'

local callbacks = {}

type Handler<T> = { context: plugin.Context, callback: T, order: number }
type Slots = {
  update: { Handler<(number) -> ()> },
  draw: { Handler<(Pass) -> ()> },
  quit: { Handler<() -> ()> },
  keypressed: { Handler<(KeyCode, number, boolean) -> ()> },
  textinput: { Handler<(string, number) -> ()> },
  surfaces: { Handler<() -> { surface.Surface }> },
}
local slots: Slots = { update = {}, draw = {}, quit = {}, keypressed = {}, textinput = {}, surfaces = {} }

local function register<T>(context: plugin.Context, list: { Handler<T> }, callback: T, order: number?): ()
  local handler: Handler<T> = { context = context, callback = callback, order = order or 0 }
  context:effect(function(): () -> ()
    list[#list + 1] = handler
    table.sort(list, function(a: Handler<T>, b: Handler<T>): boolean
      return a.order < b.order
    end)
    return function(): ()
      local index = table.find(list, handler)
      if index then
        table.remove(list, index)
      end
    end
  end)
end

function callbacks.onUpdate(context: plugin.Context, callback: (number) -> (), order: number?): ()
  register(context, slots.update, callback, order)
end

function callbacks.onDraw(context: plugin.Context, callback: (Pass) -> (), order: number?): ()
  register(context, slots.draw, callback, order)
end

function callbacks.onQuit(context: plugin.Context, callback: () -> ()): ()
  register(context, slots.quit, callback, nil)
end

function callbacks.onKeypressed(context: plugin.Context, callback: (KeyCode, number, boolean) -> ()): ()
  register(context, slots.keypressed, callback, nil)
end

function callbacks.onTextinput(context: plugin.Context, callback: (string, number) -> ()): ()
  register(context, slots.textinput, callback, nil)
end

function callbacks.onSurfaces(context: plugin.Context, callback: () -> { surface.Surface }): ()
  register(context, slots.surfaces, callback, nil)
end

function callbacks.surfaces(): { surface.Surface }
  local result: { surface.Surface } = {}
  local function add(value: surface.Surface): ()
    result[#result + 1] = value
  end
  for _, handler in ipairs(table.clone(slots.surfaces)) do
    if handler.context:active() then
      for _, candidate in ipairs(handler.callback()) do
        add(candidate)
      end
    end
  end
  return result
end

local function protected(callback: () -> ()): ()
  local ok, failure = pcall(callback)
  if not ok then
    logging.report('quit callback failed: ' .. tostring(failure), 'error')
  end
end

function callbacks.install(start: () -> (), stop: () -> ()): ()
  function lovr.load(...: unknown)
    start()
  end

  function lovr.update(dt: number)
    for _, handler in ipairs(table.clone(slots.update)) do
      if handler.context:active() then
        handler.callback(dt)
      end
    end
  end

  function lovr.draw(pass: Pass): boolean
    for _, handler in ipairs(table.clone(slots.draw)) do
      if handler.context:active() then
        handler.callback(pass)
      end
    end
    return false
  end

  function lovr.quit(): boolean
    for _, handler in ipairs(table.clone(slots.quit)) do
      if handler.context:active() then
        protected(handler.callback)
      end
    end
    protected(stop)
    return false
  end

  function lovr.keypressed(key: KeyCode, scancode: number, isrepeat: boolean)
    for _, handler in ipairs(table.clone(slots.keypressed)) do
      if handler.context:active() then
        handler.callback(key, scancode, isrepeat)
      end
    end
  end

  function lovr.textinput(text: string, code: number)
    for _, handler in ipairs(table.clone(slots.textinput)) do
      if handler.context:active() then
        handler.callback(text, code)
      end
    end
  end
end

return callbacks

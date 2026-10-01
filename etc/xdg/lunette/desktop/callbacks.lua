-- LÖVR callbacks dispatched only to active configuration scopes.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local surface = require '@lunette-contracts/surface'

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

-- Every handler of a callback runs under its own protected call. A handler's
-- error is reported through lunette.reportError, the path a raising callback
-- takes, and the handlers after it still run: one consumer's defect must not
-- hide another's frame, including the error display that would show it.
local function protected(callback: string, run: () -> ()): boolean
  local message: string? = nil
  local traceback = ''
  xpcall(run, function(raised: unknown)
    message = tostring(raised)
    traceback = debug.traceback('', 2)
  end)
  if message then
    lunette.reportError('lovr.' .. callback, message, traceback)
    return false
  end
  return true
end

local function dispatch<T>(callback: string, list: { Handler<T> }, call: (T) -> ()): ()
  for _, handler in ipairs(table.clone(list)) do
    if handler.context:active() then
      protected(callback, function()
        call(handler.callback)
      end)
    end
  end
end

function callbacks.surfaces(): { surface.Surface }
  local result: { surface.Surface } = {}
  dispatch('surfaces', slots.surfaces, function(offer: () -> { surface.Surface })
    for _, candidate in ipairs(offer()) do
      result[#result + 1] = candidate
    end
  end)
  return result
end

function callbacks.install(start: () -> (), stop: () -> ()): ()
  function lovr.load(...: unknown)
    start()
  end

  function lovr.update(dt: number)
    dispatch('update', slots.update, function(handler: (number) -> ())
      handler(dt)
    end)
  end

  function lovr.draw(pass: Pass): boolean
    dispatch('draw', slots.draw, function(handler: (Pass) -> ())
      handler(pass)
    end)
    return false
  end

  -- Returning false never vetoes the quit, whatever a handler raised.
  function lovr.quit(): boolean
    dispatch('quit', slots.quit, function(handler: () -> ())
      handler()
    end)
    protected('quit', stop)
    return false
  end

  function lovr.keypressed(key: KeyCode, scancode: number, isrepeat: boolean)
    dispatch('keypressed', slots.keypressed, function(handler: (KeyCode, number, boolean) -> ())
      handler(key, scancode, isrepeat)
    end)
  end

  function lovr.textinput(text: string, code: number)
    dispatch('textinput', slots.textinput, function(handler: (string, number) -> ())
      handler(text, code)
    end)
  end
end

return callbacks

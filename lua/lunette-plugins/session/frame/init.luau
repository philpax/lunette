-- LÖVR callbacks dispatch to the active frame provider and do nothing during provider outages.
local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/frame'
local protected = require '@lunette-plugins/diagnostics/protected-call'
local inspection = require '@lunette-contracts/inspection'
local translation = require '@self/private/translation'

local frame = {}

export type Hooks = {
  read start: () -> (),
  read stop: () -> (),
}

type Dispatcher = {
  update: (number) -> (),
  draw: (Pass) -> (),
  key: (KeyCode, number, boolean, translation.LovrModifiers?) -> (),
  text: (string, number) -> (),
  mouse: (contract.HostMouseEvent) -> (),
  quit: () -> (),
}

type Entry<T> = {
  owner: contract.Owner,
  rank: number,
  order: number,
  sequence: number,
  run: T,
  active: boolean,
}

-- A single frame activation owns LÖVR callbacks at a time.
local bound: Dispatcher? = nil

local function ranks(names: { read [number]: string }): { [string]: number }
  local result: { [string]: number } = {}
  for index = 1, #names do
    result[names[index]] = index
  end
  return result
end

-- The fields one registration operation accepts. An operation without phases takes only `run`.
type Spec = {
  read phases: { read ranks: { [string]: number }, read names: string, read default: string? }?,
}

local INPUT_RANKS = ranks(contract.INPUT_PHASES)
local UNPHASED: Spec = {}
local UPDATE: Spec = {
  phases = { ranks = ranks(contract.UPDATE_PHASES), names = table.concat(contract.UPDATE_PHASES, ', ') },
}
local DRAW: Spec = {
  phases = { ranks = ranks(contract.DRAW_PHASES), names = table.concat(contract.DRAW_PHASES, ', ') },
}
local INPUT: Spec = {
  phases = { ranks = INPUT_RANKS, names = table.concat(contract.INPUT_PHASES, ', '), default = 'binding' },
}

-- Each mouse event is reported under the name of the LÖVR callback that delivered it.
local MOUSE_LABELS: { [string]: string } = {
  move = 'lovr.mousemoved',
  press = 'lovr.mousepressed',
  release = 'lovr.mousereleased',
  wheel = 'lovr.wheelmoved',
}

local PHASED_KEYS: { string } = { 'phase', 'order', 'run' }
local UNPHASED_KEYS: { string } = { 'run' }
local HOOK_KEYS: { string } = { 'start', 'stop' }

local function validate(operation: string, handler: unknown, spec: Spec): (number, number)
  local level = 3
  if type(handler) ~= 'table' then
    error(string.format('frame %s: a handler is a table of fields, not a %s', operation, type(handler)), level)
  end
  if getmetatable(handler) ~= nil then
    error(string.format('frame %s: a handler is a plain table', operation), level)
  end
  local phases = spec.phases
  if phases then
    plugin.rejectUnknownFields('frame ' .. operation, handler, PHASED_KEYS, level)
  else
    plugin.rejectUnknownFields('frame ' .. operation, handler, UNPHASED_KEYS, level)
  end
  local raw = handler :: { [unknown]: unknown }
  if type(raw.run) ~= 'function' then
    error(string.format('frame %s: run is a function, not a %s', operation, type(raw.run)), level)
  end
  local order = raw.order
  if order ~= nil and (type(order) ~= 'number' or order ~= order or math.abs(order) == math.huge) then
    error(string.format('frame %s: order is a finite number, not %s', operation, tostring(order)), level)
  end
  local rank = 0
  if phases then
    local phase = raw.phase
    if phase == nil then
      phase = phases.default
    end
    local found = type(phase) == 'string' and phases.ranks[phase] or nil
    if found == nil then
      error(string.format('frame %s: phase is one of %s, not %s', operation, phases.names, tostring(phase)), level)
    end
    rank = found
  end
  return rank, (order :: number?) or 0
end

local function before<T>(a: Entry<T>, b: Entry<T>): boolean
  if a.rank ~= b.rank then
    return a.rank < b.rank
  end
  if a.order ~= b.order then
    return a.order < b.order
  end
  return a.sequence < b.sequence
end

local function create(context: plugin.Context): (contract.Service, Dispatcher)
  local sequence = 0
  local batchId = 0
  local currentBatch: contract.Batch? = nil
  local batches: { Entry<(contract.Batch) -> ()> } = {}
  local updates: { Entry<(number) -> ()> } = {}
  local draws: { Entry<(Pass) -> ()> } = {}
  local keys: { Entry<(contract.HostKeyEvent) -> boolean?> } = {}
  local texts: { Entry<(contract.HostTextEvent) -> boolean?> } = {}
  local mice: { Entry<(contract.HostMouseEvent) -> ()> } = {}
  local quits: { Entry<() -> ()> } = {}

  local function register<T>(
    list: { Entry<T> },
    owner: contract.Owner,
    rank: number,
    order: number,
    run: T
  ): (plugin.Effect, Entry<T>)
    sequence += 1
    local entry: Entry<T> = {
      owner = owner,
      rank = rank,
      order = order,
      sequence = sequence,
      run = run,
      active = true,
    }
    local effect = context:acquire(owner, function(): () -> ()
      list[#list + 1] = entry
      table.sort(list, before)
      return function(): ()
        entry.active = false
        local index = table.find(list, entry)
        if index then
          table.remove(list, index)
        end
      end
    end)
    return effect, entry
  end

  -- A handler disposed or unloaded during dispatch is skipped.
  local function dispatch<T>(label: string, list: { Entry<T> }, call: (T) -> boolean?): number?
    for _, entry in ipairs(table.clone(list)) do
      if entry.active and context:owns(entry.owner) then
        local consumed: boolean? = nil
        local ok = protected.call(label, function(): ()
          consumed = call(entry.run)
        end)
        if ok and consumed == true then
          return entry.rank
        end
      end
    end
    return nil
  end

  local function notifyBatch(batch: contract.Batch): ()
    currentBatch = batch
    dispatch('frame.onBatch', batches, function(run: (contract.Batch) -> ()): boolean?
      if currentBatch == batch then
        run(batch)
      end
      return nil
    end)
  end

  local function blockText(id: number): boolean
    local batch = currentBatch
    if not context:active() or batch == nil or batch.id ~= id then
      return false
    end
    if not batch.textBlocked then
      notifyBatch(table.freeze { id = batch.id, textBlocked = true })
    end
    return true
  end

  local function openBatch(): contract.Batch
    batchId += 1
    local batch: contract.Batch = table.freeze { id = batchId, textBlocked = false }
    notifyBatch(batch)
    return batch
  end

  local dispatcher: Dispatcher = {
    update = function(dt: number): ()
      openBatch()
      dispatch('lovr.update', updates, function(run: (number) -> ()): boolean?
        run(dt)
        return nil
      end)
    end,
    draw = function(pass: Pass): ()
      dispatch('lovr.draw', draws, function(run: (Pass) -> ()): boolean?
        run(pass)
        return nil
      end)
    end,
    key = function(key: KeyCode, scancode: number, isRepeat: boolean, host: translation.LovrModifiers?): ()
      local snapshot = if host ~= nil then translation.snapshot(host) else nil
      local batch = currentBatch or openBatch()
      local event: contract.HostKeyEvent = table.freeze {
        batch = batch.id,
        key = key,
        scancode = scancode,
        isRepeat = isRepeat,
        code = translation.FROM_LOVR[key],
        modifiers = table.freeze(
          if snapshot ~= nil
            then translation.fromHost(snapshot, lovr.system.isKeyDown)
            else translation.held(lovr.system.isKeyDown)
        ),
        physicalModifiers = snapshot,
      }
      local consumedRank = dispatch(
        'lovr.keypressed',
        keys,
        function(run: (contract.HostKeyEvent) -> boolean?): boolean?
          return run(event)
        end
      )
      if consumedRank == INPUT_RANKS.binding then
        blockText(event.batch)
      end
    end,
    text = function(text: string, code: number): ()
      local batch = currentBatch or openBatch()
      local event: contract.HostTextEvent = table.freeze {
        batch = batch.id,
        text = text,
        code = code,
        modifiers = table.freeze(translation.held(lovr.system.isKeyDown)),
      }
      dispatch('lovr.textinput', texts, function(run: (contract.HostTextEvent) -> boolean?): boolean?
        return run(event)
      end)
    end,
    mouse = function(event: contract.HostMouseEvent): ()
      local frozen = table.freeze(event)
      dispatch(MOUSE_LABELS[event.kind], mice, function(run: (contract.HostMouseEvent) -> ()): boolean?
        run(frozen)
        return nil
      end)
    end,
    quit = function(): ()
      dispatch('lovr.quit', quits, function(run: () -> ()): boolean?
        run()
        return nil
      end)
    end,
  }

  local function describe<T>(
    result: { inspection.Registration },
    source: string,
    list: { Entry<T> },
    phases: { read [number]: string },
    unphased: string?
  ): ()
    for _, entry in ipairs(list) do
      result[#result + 1] = inspection.registration(
        'handler',
        source,
        entry.owner,
        nil,
        entry.active and context:owns(entry.owner),
        { phase = phases[entry.rank] or unphased or 'quit', order = entry.order, sequence = entry.sequence }
      )
    end
  end
  local service: contract.Service = {
    inspect = function(_self: contract.Service): inspection.Snapshot
      local result: { inspection.Registration } = {}
      describe(result, 'frame.onBatch', batches, {}, 'batch')
      describe(result, 'frame.onUpdate', updates, contract.UPDATE_PHASES)
      describe(result, 'frame.onDraw', draws, contract.DRAW_PHASES)
      describe(result, 'frame.onKey', keys, contract.INPUT_PHASES)
      describe(result, 'frame.onText', texts, contract.INPUT_PHASES)
      describe(result, 'frame.onMouse', mice, {}, 'mouse')
      describe(result, 'frame.onQuit', quits, {})
      return inspection.snapshot(result, { active = context:active() })
    end,
    blockText = function(_self: contract.Service, id: number): boolean
      return blockText(id)
    end,
    onBatch = function(_self: contract.Service, owner: contract.Owner, handler: contract.BatchHandler): plugin.Effect
      local rank, order = validate('onBatch', handler, UNPHASED)
      local effect, entry = register(batches, owner, rank, order, handler.run)
      local batch = currentBatch
      if batch and entry.active and context:owns(owner) then
        protected.call('frame.onBatch', function(): ()
          entry.run(batch)
        end)
      end
      return effect
    end,
    onUpdate = function(_self: contract.Service, owner: contract.Owner, handler: contract.UpdateHandler): plugin.Effect
      local rank, order = validate('onUpdate', handler, UPDATE)
      return (register(updates, owner, rank, order, handler.run))
    end,
    onDraw = function(_self: contract.Service, owner: contract.Owner, handler: contract.DrawHandler): plugin.Effect
      local rank, order = validate('onDraw', handler, DRAW)
      return (register(draws, owner, rank, order, handler.run))
    end,
    onKey = function(_self: contract.Service, owner: contract.Owner, handler: contract.KeyHandler): plugin.Effect
      local rank, order = validate('onKey', handler, INPUT)
      return (register(keys, owner, rank, order, handler.run))
    end,
    onText = function(_self: contract.Service, owner: contract.Owner, handler: contract.TextHandler): plugin.Effect
      local rank, order = validate('onText', handler, INPUT)
      return (register(texts, owner, rank, order, handler.run))
    end,
    onMouse = function(_self: contract.Service, owner: contract.Owner, handler: contract.MouseHandler): plugin.Effect
      local rank, order = validate('onMouse', handler, UNPHASED)
      return (register(mice, owner, rank, order, handler.run))
    end,
    onQuit = function(_self: contract.Service, owner: contract.Owner, handler: contract.QuitHandler): plugin.Effect
      local rank, order = validate('onQuit', handler, UNPHASED)
      return (register(quits, owner, rank, order, handler.run))
    end,
  }
  return service, dispatcher
end

export type Config = {}
export type Settings = {}
export type Service = contract.Service

-- Callback binding belongs to the provider effect, including when a plugin wraps its service.
local function build(context: plugin.Context): Service
  local service, dispatcher = create(context)
  context:effect(function(): () -> ()
    if bound then
      error('frame: another frame activation already receives the LÖVR callbacks', 0)
    end
    bound = dispatcher
    return function(): ()
      if bound == dispatcher then
        bound = nil
      end
    end
  end)
  return service
end

local provider = plugin.provider<<Config, Settings, Service>> {
  name = 'frame',
  capability = contract.capability,
  build = build,
}
frame.definition = provider.definition

-- Starts from `lovr.load` and stops after quit handlers. `lovr.quit` always returns false.
function frame.install(hooks: Hooks): ()
  if type(hooks) ~= 'table' then
    error('frame install: the hooks are a table of fields, not a ' .. type(hooks), 2)
  end
  plugin.rejectUnknownFields('frame install', hooks, HOOK_KEYS, 2)
  local start, stop = hooks.start, hooks.stop
  if type(start) ~= 'function' or type(stop) ~= 'function' then
    error('frame install: start and stop are functions', 2)
  end

  function lovr.load(...: unknown)
    start()
  end

  function lovr.update(dt: number)
    local current = bound
    if current then
      current.update(dt)
    end
  end

  function lovr.draw(pass: Pass): boolean
    local current = bound
    if current then
      current.draw(pass)
    end
    return false
  end

  function lovr.keypressed(key: KeyCode, scancode: number, isrepeat: boolean, modifiers: translation.LovrModifiers?)
    local current = bound
    if current then
      current.key(key, scancode, isrepeat, modifiers)
    end
  end

  function lovr.textinput(text: string, code: number)
    local current = bound
    if current then
      current.text(text, code)
    end
  end

  function lovr.mousemoved(x: number, y: number, dx: number, dy: number)
    local current = bound
    if current then
      current.mouse { kind = 'move', x = x, y = y, dx = dx, dy = dy }
    end
  end

  function lovr.mousepressed(x: number, y: number, button: number)
    local current = bound
    if current then
      current.mouse { kind = 'press', x = x, y = y, button = button }
    end
  end

  function lovr.mousereleased(x: number, y: number, button: number)
    local current = bound
    if current then
      current.mouse { kind = 'release', x = x, y = y, button = button }
    end
  end

  function lovr.wheelmoved(dx: number, dy: number)
    local current = bound
    if current then
      current.mouse { kind = 'wheel', dx = dx, dy = dy }
    end
  end

  function lovr.quit(): boolean
    local current = bound
    if current then
      current.quit()
    end
    protected.call('lovr.quit', stop)
    return false
  end
end

return frame

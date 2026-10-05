-- LÖVR callbacks dispatch to the active frame provider and do nothing during provider outages.
local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/frame'
local protected = require '@lunette-plugins/protected'
local inspection = require '@lunette-contracts/inspection'
local keyContract = require '@lunette-contracts/keys'

local frame = {}

export type Hooks = {
  read start: () -> (),
  read stop: () -> (),
}

type Dispatcher = {
  update: (number) -> (),
  draw: (Pass) -> (),
  key: (KeyCode, number, boolean, keyContract.PhysicalModifiers?) -> (),
  text: (string, number) -> (),
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

local PHASE_RANKS = ranks(contract.PHASES)
local INPUT_PHASE_RANKS = ranks(contract.INPUT_PHASES)
local PHASE_NAMES = table.concat(contract.PHASES, ', ')
local INPUT_PHASE_NAMES = table.concat(contract.INPUT_PHASES, ', ')

local PHASED_KEYS: { [string]: boolean } = { phase = true, order = true, run = true }
local QUIT_KEYS: { [string]: boolean } = { run = true }
local HOOK_KEYS: { [string]: boolean } = { start = true, stop = true }

local function validate(
  operation: string,
  handler: unknown,
  allowed: { [string]: boolean },
  phaseRanks: { [string]: number }?,
  defaultPhase: string?,
  phaseNames: string?
): (number, number)
  local level = 3
  if type(handler) ~= 'table' then
    error(string.format('frame %s: a handler is a table of fields, not a %s', operation, type(handler)), level)
  end
  if getmetatable(handler) ~= nil then
    error(string.format('frame %s: a handler is a plain table', operation), level)
  end
  local fields = if allowed == QUIT_KEYS then 'run' else 'phase, order, and run'
  plugin.rejectUnknownFields('frame ' .. operation, handler, allowed, fields, level)
  local raw = handler :: { [unknown]: unknown }
  if type(raw.run) ~= 'function' then
    error(string.format('frame %s: run is a function, not a %s', operation, type(raw.run)), level)
  end
  local order = raw.order
  if order ~= nil and (type(order) ~= 'number' or order ~= order or math.abs(order) == math.huge) then
    error(string.format('frame %s: order is a finite number, not %s', operation, tostring(order)), level)
  end
  local rank = 0
  if phaseRanks then
    local phase = raw.phase
    if phase == nil then
      phase = defaultPhase
    end
    local found = type(phase) == 'string' and phaseRanks[phase] or nil
    if found == nil then
      error(
        string.format('frame %s: phase is one of %s, not %s', operation, tostring(phaseNames), tostring(phase)),
        level
      )
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
  local keys: { Entry<(contract.KeyEvent) -> boolean?> } = {}
  local texts: { Entry<(contract.TextEvent) -> boolean?> } = {}
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
    key = function(key: KeyCode, scancode: number, isRepeat: boolean, modifiers: keyContract.PhysicalModifiers?): ()
      local snapshot = if modifiers ~= nil then keyContract.snapshotPhysicalModifiers(modifiers) else nil
      local batch = currentBatch or openBatch()
      local event: contract.KeyEvent = table.freeze {
        batch = batch.id,
        key = key,
        scancode = scancode,
        isRepeat = isRepeat,
        modifiers = snapshot,
      }
      local consumedRank = dispatch('lovr.keypressed', keys, function(run: (contract.KeyEvent) -> boolean?): boolean?
        return run(event)
      end)
      if consumedRank == INPUT_PHASE_RANKS.binding then
        blockText(event.batch)
      end
    end,
    text = function(text: string, code: number): ()
      local batch = currentBatch or openBatch()
      local event: contract.TextEvent = table.freeze { batch = batch.id, text = text, code = code }
      dispatch('lovr.textinput', texts, function(run: (contract.TextEvent) -> boolean?): boolean?
        return run(event)
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
      describe(result, 'frame.onUpdate', updates, contract.PHASES)
      describe(result, 'frame.onDraw', draws, contract.PHASES)
      describe(result, 'frame.onKey', keys, contract.INPUT_PHASES)
      describe(result, 'frame.onText', texts, contract.INPUT_PHASES)
      describe(result, 'frame.onQuit', quits, {})
      return inspection.snapshot(result, { active = context:active() })
    end,
    blockText = function(_self: contract.Service, id: number): boolean
      return blockText(id)
    end,
    onBatch = function(_self: contract.Service, owner: contract.Owner, handler: contract.BatchHandler): plugin.Effect
      local rank, order = validate('onBatch', handler, QUIT_KEYS, nil, nil, nil)
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
      local rank, order = validate('onUpdate', handler, PHASED_KEYS, PHASE_RANKS, nil, PHASE_NAMES)
      return (register(updates, owner, rank, order, handler.run))
    end,
    onDraw = function(_self: contract.Service, owner: contract.Owner, handler: contract.DrawHandler): plugin.Effect
      local rank, order = validate('onDraw', handler, PHASED_KEYS, PHASE_RANKS, nil, PHASE_NAMES)
      return (register(draws, owner, rank, order, handler.run))
    end,
    onKey = function(_self: contract.Service, owner: contract.Owner, handler: contract.KeyHandler): plugin.Effect
      local rank, order = validate('onKey', handler, PHASED_KEYS, INPUT_PHASE_RANKS, 'binding', INPUT_PHASE_NAMES)
      return (register(keys, owner, rank, order, handler.run))
    end,
    onText = function(_self: contract.Service, owner: contract.Owner, handler: contract.TextHandler): plugin.Effect
      local rank, order = validate('onText', handler, PHASED_KEYS, INPUT_PHASE_RANKS, 'binding', INPUT_PHASE_NAMES)
      return (register(texts, owner, rank, order, handler.run))
    end,
    onQuit = function(_self: contract.Service, owner: contract.Owner, handler: contract.QuitHandler): plugin.Effect
      local rank, order = validate('onQuit', handler, QUIT_KEYS, nil, nil, nil)
      return (register(quits, owner, rank, order, handler.run))
    end,
  }
  return service, dispatcher
end

local config = require '@lunette-plugins/frame/config'

export type Config = config.Config
export type Settings = config.Settings
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
  schema = config,
  capability = contract.capability,
  build = build,
}
frame.definition = provider.definition
frame.define = provider.define
frame.build = provider.build
frame.requires = provider.requires

-- Starts from `lovr.load` and stops after quit handlers. `lovr.quit` always returns false.
function frame.install(hooks: Hooks): ()
  if type(hooks) ~= 'table' then
    error('frame install: the hooks are a table of fields, not a ' .. type(hooks), 2)
  end
  plugin.rejectUnknownFields('frame install', hooks, HOOK_KEYS, 'start and stop', 2)
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

  function lovr.keypressed(key: KeyCode, scancode: number, isrepeat: boolean, modifiers: keyContract.PhysicalModifiers?)
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

  function lovr.quit(): boolean
    local current = bound
    if current then
      current.quit()
    end
    protected.call('lovr.quit', stop)
    return false
  end
end

-- Validates entries before binding callbacks, then starts and closes their runtime through LÖVR callbacks.
function frame.run(entries: { plugin.Entry }): ()
  local checked = plugin.compose(entries)
  local running: plugin.Running? = nil
  frame.install {
    start = function(): ()
      if running then
        return
      end
      running = plugin.start(checked)
    end,
    stop = function(): ()
      local current = running
      running = nil
      if current then
        current.runtime:close()
      end
    end,
  }
end

return frame

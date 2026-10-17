local testing = require '@testing'
local uiHost = require '@lunette-contracts/ui-host'
local ui = require '@lunette-plugins/ui/react'
local fixture = require '@testing/ui-host'
local expect = testing.expect
local test = testing.suite()

local element = uiHost.element

local function boot(): fixture.State
  return fixture.boot {
    setup = function(service: uiHost.Service, owner: any): ()
      fixture.registerKinds(service, owner, {})
    end,
  }
end

local function counted<T>(initial: T): any
  local source = ui.store(initial)
  local counts = { active = 0, subscribed = 0, cleaned = 0 }
  local store = {
    get = function(): T
      return source:get()
    end,
    set = function(_self: any, value: T): ()
      source:set(value)
    end,
    subscribe = function(_self: any, listener: (T) -> ()): () -> ()
      local unsubscribe = source:subscribe(listener)
      counts.active += 1
      counts.subscribed += 1
      local active = true
      return function(): ()
        if active then
          active = false
          counts.active -= 1
          counts.cleaned += 1
          unsubscribe()
        end
      end
    end,
  }
  return { store = store, counts = counts }
end

local function text(state: fixture.State): string?
  local node = state.panel:find ''
  return if node then node.props.text else nil
end

local function takeFailure(state: fixture.State, message: string): ()
  local reports = state.fixture.native.events.reported
  local found = false
  for _, report in reports do
    if string.find(report.message, message, 1, true) then
      found = true
    end
  end
  table.clear(reports)
  expect.truthy(found, 'the failure is reported')
end

test('a failed initial render acquires no store subscription and can retry', function()
  local state = boot()
  local value = counted(1)
  local failing = ui.store(true)
  local Reader = ui.component('InitialStoreReader', function(props: { failing: boolean }): ui.Child
    local current = ui.useStore(value.store)
    if props.failing then
      error 'deliberate initial store render failure'
    end
    return element('test/text', { key = 'value', text = tostring(current) })
  end)
  local Root = ui.component('InitialStoreRoot', function(): ui.Child
    return Reader { failing = ui.useStore(failing) }
  end)
  local handle = ui.mount(state.panel, Root {})
  state.fixture:step()
  takeFailure(state, 'deliberate initial store render failure')
  expect.equal(value.counts.subscribed, 0, 'a failed render acquires nothing')
  expect.equal(value.counts.active, 0)
  failing:set(false)
  state.fixture:step()
  expect.equal(text(state), '1')
  expect.equal(value.counts.active, 1, 'the successful retry subscribes once')
  value.store:set(2)
  state.fixture:step()
  expect.equal(text(state), '2')
  handle:unmount()
  expect.equal(value.counts.active, 0)
  expect.equal(value.counts.cleaned, 1)
  state.fixture:close()
end)

test('a failed store switch keeps the previous subscription until a successful retry', function()
  local state = boot()
  local first, second = counted(1), counted(10)
  local choice = ui.store { store = first.store, failing = false }
  local renders = 0
  local Reader = ui.component('SwitchingStoreReader', function(props: { store: any, failing: boolean }): ui.Child
    renders += 1
    local current = ui.useStore(props.store)
    if props.failing then
      error 'deliberate store switch failure'
    end
    return element('test/text', { key = 'value', text = tostring(current) })
  end)
  local Root = ui.component('SwitchingStoreRoot', function(): ui.Child
    return Reader(ui.useStore(choice))
  end)
  local handle = ui.mount(state.panel, Root {})
  state.fixture:step()
  expect.equal(first.counts.active, 1)
  choice:set { store = second.store, failing = true }
  state.fixture:step()
  takeFailure(state, 'deliberate store switch failure')
  expect.equal(text(state), '1', 'the previous output stays')
  expect.equal(first.counts.active, 1, 'the previous subscription stays')
  expect.equal(second.counts.subscribed, 0, 'the failed replacement acquires nothing')
  local before = renders
  second.store:set(11)
  state.fixture:step()
  expect.equal(renders, before, 'the rejected store does not schedule renders')
  choice:set { store = first.store, failing = false }
  state.fixture:step()
  first.store:set(2)
  state.fixture:step()
  expect.equal(text(state), '2', 'the original store still drives the component')
  choice:set { store = second.store, failing = false }
  state.fixture:step()
  expect.equal(text(state), '11')
  expect.equal(first.counts.active, 0)
  expect.equal(first.counts.cleaned, 1)
  expect.equal(second.counts.active, 1)
  first.store:set(3)
  state.fixture:step()
  expect.equal(text(state), '11', 'the previous store no longer drives the component')
  second.store:set(12)
  state.fixture:step()
  expect.equal(text(state), '12')
  handle:unmount()
  expect.equal(second.counts.active, 0)
  expect.equal(second.counts.cleaned, 1)
  state.fixture:close()
end)

test('a failed store switch releases only the previous subscription on unmount', function()
  local state = boot()
  local first, second = counted(1), counted(10)
  local choice = ui.store(false)
  local Reader = ui.component('UnmountingStoreReader', function(): ui.Child
    local switching = ui.useStore(choice)
    local current = ui.useStore(if switching then second.store else first.store)
    if switching then
      error 'deliberate store unmount failure'
    end
    return element('test/text', { key = 'value', text = tostring(current) })
  end)
  local handle = ui.mount(state.panel, Reader {})
  state.fixture:step()
  choice:set(true)
  state.fixture:step()
  takeFailure(state, 'deliberate store unmount failure')
  handle:unmount()
  expect.equal(first.counts.active, 0)
  expect.equal(first.counts.cleaned, 1)
  expect.equal(second.counts.active, 0, 'the failed replacement leaves no subscription behind')
  expect.equal(second.counts.subscribed, 0)
  state.fixture:close()
end)

test('store updates between reading and subscribing reach the next render', function()
  local state = boot()
  local source = ui.store(1)
  local firstRead = true
  local store = {
    get = function(): number
      local value = source:get()
      if firstRead then
        firstRead = false
        source:set(2)
      end
      return value
    end,
    subscribe = function(_self: any, listener: (number) -> ()): () -> ()
      return source:subscribe(listener)
    end,
  }
  local Reader = ui.component('StoreGapReader', function(): ui.Child
    return element('test/text', { key = 'value', text = tostring(ui.useStore(store)) })
  end)
  ui.mount(state.panel, Reader {})
  state.fixture:step()
  state.fixture:step()
  expect.equal(text(state), '2', 'the update before subscription is not lost')
  state.fixture:close()
end)

test('store notifications and value equality retain their existing rules', function()
  local state = boot()
  local initial = { value = 1 }
  local source = ui.store(initial)
  local notify: ((any) -> ())? = nil
  local store = {
    get = function(): any
      return source:get()
    end,
    subscribe = function(_self: any, listener: (any) -> ()): () -> ()
      notify = listener
      return source:subscribe(listener)
    end,
  }
  local renders = 0
  local Reader = ui.component('StoreEqualityReader', function(): ui.Child
    renders += 1
    local value = ui.useStore(store)
    return element('test/text', { key = 'value', text = tostring(value.value) })
  end)
  ui.mount(state.panel, Reader {})
  state.fixture:step()
  expect.equal(renders, 1, 'an unchanged snapshot does not schedule an extra render')
  source:set(initial)
  state.fixture:step()
  expect.equal(renders, 1, 'setting the same table does not notify')
  source:set { value = 1 }
  state.fixture:step()
  expect.equal(renders, 2, 'a different table notifies even with equal fields')
  assert(notify)(source:get())
  state.fixture:step()
  expect.equal(renders, 3, 'a notification schedules a render even for an unchanged value')
  state.fixture:close()
end)

test('a failed subscription is reported and retries on the next render', function()
  local state = boot()
  local value = counted(1)
  local refresh = ui.store(0)
  local attempts = 0
  local store = {
    get = function(): number
      return value.store:get()
    end,
    subscribe = function(_self: any, listener: (number) -> ()): () -> ()
      attempts += 1
      if attempts == 1 then
        error 'deliberate subscription failure'
      end
      return value.store:subscribe(listener)
    end,
  }
  local Reader = ui.component('RetryingStoreReader', function(): ui.Child
    ui.useStore(refresh)
    return element('test/text', { text = tostring(ui.useStore(store)) })
  end)
  local handle = ui.mount(state.panel, Reader {})
  state.fixture:step()
  takeFailure(state, 'deliberate subscription failure')
  expect.equal(value.counts.active, 0)
  refresh:set(1)
  state.fixture:step()
  expect.equal(attempts, 2, 'the same store retries after subscription fails')
  expect.equal(value.counts.active, 1)
  value.store:set(2)
  state.fixture:step()
  expect.equal(text(state), '2')
  handle:unmount()
  expect.equal(value.counts.active, 0)
  state.fixture:close()
end)

test('a failed snapshot check retains the acquired subscription for cleanup', function()
  local state = boot()
  local value = counted(1)
  local reads = 0
  local store = {
    get = function(): number
      reads += 1
      if reads == 2 then
        error 'deliberate snapshot check failure'
      end
      return value.store:get()
    end,
    subscribe = function(_self: any, listener: (number) -> ()): () -> ()
      return value.store:subscribe(listener)
    end,
  }
  local Reader = ui.component('SnapshotStoreReader', function(): ui.Child
    return element('test/text', { text = tostring(ui.useStore(store)) })
  end)
  local handle = ui.mount(state.panel, Reader {})
  state.fixture:step()
  takeFailure(state, 'deliberate snapshot check failure')
  expect.equal(value.counts.active, 1)
  handle:unmount()
  expect.equal(value.counts.active, 0, 'a failed snapshot check does not lose the cleanup')
  state.fixture:close()
end)

test('an earlier effect changing a store cannot leave the rendered snapshot stale', function()
  local state = boot()
  local value = counted(1)
  local field = nil
  local Reader = ui.component('EffectStoreReader', function(): ui.Child
    local ref = ui.useRef(nil :: uiHost.Node?)
    ui.useEffect(function(owner: any): (() -> ())?
      expect.equal(owner, state.owner, 'the effect receives the mount owner')
      field = ref.current
      expect.truthy(field and not field.dead, 'refs are assigned before effects')
      value.store:set(2)
      return nil
    end, {})
    local current = ui.useStore(value.store)
    return element('test/text', { ref = ref, text = tostring(current) })
  end)
  ui.mount(state.panel, Reader {}, { owner = state.owner })
  state.fixture:step()
  state.fixture:step()
  expect.equal(text(state), '2')
  expect.equal(state.panel:find '', field, 'the update keeps the ref node')
  expect.equal(value.counts.subscribed, 1)
  state.fixture:close()
end)

return test

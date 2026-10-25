local testing = require '@testing'
local plugin = require '@lunette-plugin'
local management = require '@lunette-plugin/management'
local schema = require '@lunette-plugin/schema'
local controller = require '../private/composition/controller'
local editor = require '../private/composition/editor'
local expect = testing.expect
local test = testing.suite()

type Environment = {
  running: management.Running,
  state: controller.State,
  overrides: { [string]: { [string]: unknown } },
  poll: (() -> ()) -> (),
  polls: () -> number,
}

local function fixture(body: (Environment) -> ()): ()
  local definition = plugin.consumer({
    name = 'publication-editor',
    schema = schema.object {
      ['1'] = schema.default(schema.number())(1),
      count = schema.default(schema.number())(1),
      title = schema.default(schema.string()) 'initial',
    },
    init = function() end,
  }).definition
  local running = management.start {
    { id = 'editable', definition = definition },
    { id = 'other', definition = definition },
  }
  local overrides: { [string]: { [string]: unknown } } = {}
  local onPoll = function() end
  local polls = 0
  local service = setmetatable({}, {
    __index = function(_self: unknown, key: string): (any, ...any) -> any
      return function(_service: any, ...: any): any
        if key == 'snapshot' then
          polls += 1
          onPoll()
        end
        local result = (running.service :: any)[key](running.service, ...)
        if key == 'entries' then
          local entries = {}
          for index, entry in result do
            local copy = table.clone(entry)
            for field, value in overrides[entry.id] or {} do
              copy[field] = value
            end
            entries[index] = copy
          end
          return entries
        end
        return result
      end
    end,
  })
  local state = controller.new(service, {})
  controller.selectEntry(state, 'editable')
  controller.invoke(state, 'configure')
  local env: Environment = {
    running = running,
    state = state,
    overrides = overrides,
    poll = function(callback: () -> ()): ()
      onPoll = callback
    end,
    polls = function(): number
      return polls
    end,
  }
  local ok, problem = pcall(body, env)
  running.runtime:close()
  if not ok then
    error(problem, 0)
  end
end

test('idle Configure polls and rebuilds callbacks without publishing unchanged visible state', function()
  fixture(function(env: Environment): ()
    local state = env.state
    local actions = state.actions
    local apply = actions.apply.run
    local polls = env.polls()
    for _ = 1, 3 do
      expect.equal(controller.update(state), false, 'an unchanged eligible poll does not publish')
    end
    expect.equal(env.polls(), polls + 3, 'every interval still reads composition')
    expect.truthy(state.actions ~= actions, 'the action map is fresh')
    expect.truthy(state.actions.apply.run ~= apply, 'callbacks are rebuilt even when publication is skipped')
    local model = assert(editor.set(assert(state.draft), { 'count' }, 7))
    state.draft = model
    expect.truthy(controller.invoke(state, 'apply'), 'invocation reads the fresh map and mutable draft')
    expect.equal(controller.selected(state).config.count, 7)
  end)
end)

local rowChanges = {
  path = { 1 },
  label = 'changed label',
  readOnly = true,
  reason = 'changed reason',
  description = 'changed description',
  text = 'changed text',
}
for field, value in rowChanges do
  test('a visible editor row change publishes: ' .. field, function()
    fixture(function(env: Environment): ()
      local state = env.state
      local rows = table.clone(state.editorRows)
      local index = nil
      for current, candidate in rows do
        if #candidate.path == 1 and candidate.path[1] == '1' then
          index = current
          break
        end
      end
      assert(index, 'the string-keyed field has a row')
      local row = table.clone(rows[index])
      row[field] = value
      rows[index] = row
      state.editorRows = rows
      expect.equal(controller.update(state), true, field .. ' changes on refresh')
      expect.equal(controller.update(state), false, 'the new visible state settles')
    end)
  end)
end

for _, field in { 'id', 'instanceId', 'state', 'protected', 'required', 'enabled' } do
  test('an entry list field change publishes: ' .. field, function()
    fixture(function(env: Environment): ()
      local state = env.state
      local entry = state.entries[2]
      local changes = {}
      changes[field] = if type(entry[field]) == 'boolean' then not entry[field] else 'changed'
      env.overrides[entry.id] = changes
      expect.equal(controller.update(state), true)
    end)
  end)
end

for _, field in { 'name', 'saved', 'baseConfig', 'previousConfig' } do
  test('external selected-entry annotations and action reasons publish: ' .. field, function()
    fixture(function(env: Environment): ()
      if field == 'baseConfig' then
        env.overrides.editable = { saved = { count = 2 }, baseConfig = { count = 1 } }
        controller.update(env.state)
      end
      env.overrides.editable = if field == 'name'
        then { name = 'changed name' }
        elseif field == 'saved' then { saved = { count = 2 } }
        elseif field == 'baseConfig' then { saved = { count = 2 }, baseConfig = { count = 5 } }
        else { previousConfig = {} }
      expect.equal(controller.update(env.state), true)
      expect.equal(controller.update(env.state), false)
    end)
  end)
end

for _, change in { 'key-added', 'key-removed', 'label', 'reason' } do
  test('an action map presentation change publishes: ' .. change, function()
    fixture(function(env: Environment): ()
      local actions = table.clone(env.state.actions)
      if change == 'key-added' then
        actions.extra = actions.apply
      elseif change == 'key-removed' then
        actions.apply = nil
      else
        local action = table.clone(actions.apply)
        action[change] = 'changed'
        actions.apply = action
      end
      env.state.actions = actions
      expect.equal(controller.update(env.state), true)
    end)
  end)
end

test('entry and option ordering, counts, status, and visible graph membership publish', function()
  fixture(function(env: Environment): ()
    local state = env.state
    local entries = table.clone(state.entries)
    entries[1], entries[2] = entries[2], entries[1]
    state.entries = entries
    expect.equal(controller.update(state), true, 'entry order')
    state.entries = { state.entries[1] }
    expect.equal(controller.update(state), true, 'entry count')
    local rows = table.clone(state.editorRows)
    rows[1], rows[2] = rows[2], rows[1]
    state.editorRows = rows
    expect.equal(controller.update(state), true, 'row order')
    state.editorRows = { state.editorRows[1] }
    expect.equal(controller.update(state), true, 'row count')
    env.poll(function()
      state.message = 'external status'
    end)
    expect.equal(controller.update(state), true, 'status text')
    env.poll(function() end)
    local snapshot = table.clone(state.view.snapshot)
    snapshot.nodes = {}
    state.view.snapshot = snapshot
    expect.equal(controller.update(state), true, 'graph node membership controls entry visibility')
  end)
end)

test('polling refreshes option rows and ignores undisplayed editor values and unsaved base values', function()
  fixture(function(env: Environment): ()
    local state = env.state
    env.poll(function()
      state.draft = assert(editor.set(assert(state.draft), { 'count' }, 4))
    end)
    expect.equal(controller.update(state), true, 'an external draft update rebuilds visible option text')
    env.poll(function() end)
    env.overrides.editable = { config = { count = 9 }, baseConfig = { count = 8 } }
    expect.equal(controller.update(state), false, 'raw config and an unsaved base value are not displayed')
    local rows = table.clone(state.editorRows)
    local row = table.clone(rows[1])
    row.value, row.choices = 42, { 1, 2 }
    rows[1] = row
    state.editorRows = rows
    expect.equal(controller.update(state), false, 'no selected row means no value or choice control is displayed')
    env.poll(function()
      state.view.transitive = not state.view.transitive
    end)
    expect.equal(controller.update(state), true, 'the Transitive chip remains visible')
  end)
end)

test('external lifecycle changes publish while an unchanged draft remains open', function()
  fixture(function(env: Environment): ()
    env.running.service:disable 'other'
    expect.equal(controller.update(env.state), true)
    env.running.service:enable 'other'
    expect.equal(controller.update(env.state), true)
    env.running.service:remove 'editable'
    expect.equal(controller.update(env.state), true, 'losing selection and draft publishes')
    expect.equal(env.state.draft, nil)
    expect.equal(controller.update(env.state), true, 'no draft is outside the optimization')
  end)
end)

local fallback = {
  catalog = function(state: controller.State): ()
    state.tab = 'catalog'
  end,
  saved = function(state: controller.State): ()
    state.tab = 'saved'
  end,
  inspect = function(state: controller.State): ()
    state.tab = 'inspect'
  end,
  graph = function(state: controller.State): ()
    state.presentation = 'graph'
  end,
  filtered = function(state: controller.State): ()
    state.view.mode = 'providers'
  end,
  query = function(state: controller.State): ()
    state.view.query = 'editable'
  end,
  search = function(state: controller.State): ()
    state.view.searchActive = true
  end,
  row = function(state: controller.State): ()
    state.row = 1
  end,
  edit = function(state: controller.State): ()
    state.edit = { operation = 'set', path = { 'count' } }
  end,
  draft = function(state: controller.State): ()
    state.draft = nil
  end,
  selection = function(state: controller.State): ()
    state.view.selection = nil
  end,
}
for name, change in fallback do
  test('polling always publishes outside idle Configure before refresh: ' .. name, function()
    fixture(function(env: Environment): ()
      change(env.state)
      expect.equal(controller.update(env.state), true)
    end)
  end)
  test('polling always publishes outside idle Configure after refresh: ' .. name, function()
    fixture(function(env: Environment): ()
      env.poll(function()
        change(env.state)
        if name == 'draft' then
          env.state.tab = 'inspect'
        end
      end)
      expect.equal(controller.update(env.state), true)
    end)
  end)
end

return test

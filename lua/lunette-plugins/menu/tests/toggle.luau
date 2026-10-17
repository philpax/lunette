local testing = require '@testing'
local toggle = require '@lunette-plugins/menu/toggle'
local expect = testing.expect
local test = testing.suite()

type Log = { calls: { string }, saved: { boolean }, action: any, selected: boolean? }

-- A context that records saves, and a menu that records the registered action and its selection.
local function fakes(): (any, any, Log)
  local log: Log = { calls = {}, saved = {}, action = nil, selected = nil }
  local context = {
    save = function(_self: any, changes: { visible: boolean }): boolean
      table.insert(log.saved, changes.visible)
      return true
    end,
  }
  local menus = {
    register = function(_self: any, _owner: any, action: any): any
      log.action, log.selected = action, action.selected
      return {
        update = function(_registration: any, state: { selected: boolean? }): boolean
          log.selected = state.selected
          return true
        end,
        dispose = function(): ()
          log.action = nil
        end,
      }
    end,
  }
  return context, menus, log
end

local function options(log: Log, visible: boolean): any
  return {
    id = 'test/panel',
    label = 'Panel',
    visible = visible,
    show = function(requested: boolean): ()
      table.insert(log.calls, if requested then 'show requested' else 'show')
    end,
    hide = function(): ()
      table.insert(log.calls, 'hide')
    end,
  }
end

test('a closed toggle opens and closes from the menu, selecting the action and saving each change', function()
  local context, menus, log = fakes()
  local opened = toggle.attach(context, menus, options(log, false))
  expect.equal(#log.calls, 0, 'nothing opens at start')
  expect.equal(log.selected, false)
  log.action.run()
  expect.equal(log.calls[1], 'show requested', 'the menu asks for it')
  expect.equal(log.selected, true, 'the action is selected while open')
  expect.equal(opened:open(), true)
  log.action.run()
  expect.equal(log.calls[2], 'hide')
  expect.equal(log.selected, false)
  expect.equal(#log.saved, 2, 'opening and closing each save')
  expect.equal(log.saved[1], true)
  expect.equal(log.saved[2], false)
end)

test('a toggle saved open opens at start without saving, and a close from elsewhere follows through', function()
  local context, menus, log = fakes()
  local opened = toggle.attach(context, menus, options(log, true))
  expect.equal(log.calls[1], 'show', 'it opens at start, not as a request')
  expect.equal(log.selected, true, 'the action registers selected')
  expect.equal(#log.saved, 0, 'opening as saved saves nothing')
  opened:set(false)
  expect.equal(log.calls[2], 'hide')
  expect.equal(log.selected, false, 'a close button deselects the action')
  expect.equal(log.saved[1], false, 'and saves it closed')
  opened:set(false)
  expect.equal(#log.calls, 2, 'closing a closed toggle does nothing')
  expect.equal(#log.saved, 1)
  opened:dispose()
  expect.equal(log.action, nil, 'disposing removes the action')
  opened:set(true)
  expect.equal(log.calls[3], 'show', 'a disposed toggle still opens what it shows')
end)

test('a toggle saves through its own function when given one', function()
  local context, menus, log = fakes()
  local fields: { boolean } = {}
  local given = options(log, false)
  given.save = function(open: boolean): ()
    table.insert(fields, open)
  end
  toggle.attach(context, menus, given)
  log.action.run()
  expect.equal(fields[1], true, 'the given function saves')
  expect.equal(#log.saved, 0, 'the context does not')
end)

return test

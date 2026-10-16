local testing = require '@testing'
local fixture = require '@testing/ui-host'
local expect = testing.expect
local test = testing.suite()

local function boot(): fixture.State
  return fixture.boot { standard = true, width = 0.4, height = 0.4 }
end

-- Presses at one point of a node, drags to another, and releases, as fractions of the node's box.
-- The width a scroll box keeps clear for its bar.
local function scrollingGutter(state: fixture.State): number
  return state.service:theme().sizes.scrollbar * 3
end

local function drag(state: fixture.State, path: string, from: { number }, to: { number }): ()
  local node = assert(state.panel:find(path), `no node at {path}`)
  local bounds = node:panelBounds()
  local geometry = fixture.geometry(state)
  local function at(point: { number }): (number, number)
    return bounds.x + bounds.width * point[1], bounds.y + bounds.height * point[2]
  end
  local runner = state.fixture
  runner:button('right', 'trigger', false)
  runner:aim(geometry, at(from))
  runner:step()
  runner:button('right', 'trigger', true)
  runner:step()
  for step = 1, 4 do
    local t = step / 4
    runner:aim(geometry, at { from[1] + (to[1] - from[1]) * t, from[2] + (to[2] - from[2]) * t })
    runner:step()
  end
  runner:button('right', 'trigger', false)
  runner:step()
end

test('a toggle reports the flipped value', function()
  local state = boot()
  local c = assert(state.components)
  local reported = {}
  fixture.show(
    state,
    c.Panel {
      c.Body {
        key = 'body',
        c.Toggle {
          key = 'backdrop',
          label = 'Backdrop',
          value = false,
          onChange = function(value: boolean)
            table.insert(reported, value)
          end,
        },
      },
    }
  )
  fixture.click(state, 'body/backdrop')
  expect.equal(#reported, 1)
  expect.equal(reported[1], true)
  state.fixture:close()
end)

test('a disabled button does not activate and shows its reason on hover', function()
  local state = boot()
  local c = assert(state.components)
  local activations = 0
  fixture.show(
    state,
    c.Panel {
      c.Body {
        key = 'body',
        c.Button {
          key = 'pin',
          label = 'Pin',
          disabledReason = 'Pinning needs the Attention source.',
          onActivate = function()
            activations += 1
          end,
        },
      },
    }
  )
  fixture.click(state, 'body/pin')
  state.fixture:step()
  expect.equal(activations, 0)
  expect.truthy(state.panel:find 'body/pin/reason', 'the reason is shown while hovered')
  state.fixture:close()
end)

test('a slider drag moves continuously, holds to a detent near it, and snaps the release', function()
  local state = boot()
  local c = assert(state.components)
  local changes, commits = {}, {}
  fixture.show(
    state,
    c.Panel {
      c.Body {
        key = 'body',
        c.Slider {
          key = 'response',
          label = 'Response',
          value = 0,
          detents = { { value = 0, label = 'None' }, { value = 0.5, label = 'Medium' }, { value = 1, label = 'Full' } },
          onChange = function(value: number)
            table.insert(changes, value)
          end,
          onCommit = function(value: number)
            table.insert(commits, value)
          end,
        },
      },
    }
  )
  drag(state, 'body/response/track', { 0.05, 0.5 }, { 0.51, 0.5 })
  expect.truthy(#changes > 2, 'each drag step reports a value')
  local between = false
  for _, change in changes do
    between = between or (change > 0.1 and change < 0.4)
  end
  expect.truthy(between, 'the value moves continuously between detents')
  expect.equal(changes[#changes - 1], 0.5, 'the drag holds to the Medium detent near it before the release')
  expect.equal(#commits, 1)
  expect.equal(commits[1], 0.5, 'the release snaps to the Medium detent')
  state.fixture:step()
  local value = assert(state.panel:find 'body/response/heading/value')
  expect.equal(value.props.text, '0.50', 'the released value is shown before the prop changes')
  state.fixture:close()
end)

test('a dropdown opens and reports the chosen option', function()
  local state = boot()
  local c = assert(state.components)
  local chosen = nil
  fixture.show(
    state,
    c.Panel {
      c.Body {
        key = 'body',
        c.Dropdown {
          key = 'layout',
          value = 'arc',
          options = { { id = 'arc', label = 'Arc' }, { id = 'grid', label = 'Grid' } },
          onChange = function(id: string)
            chosen = id
          end,
        },
      },
    }
  )
  expect.equal(state.panel:find 'body/layout/menu', nil, 'the menu starts closed')
  fixture.click(state, 'body/layout/trigger')
  state.fixture:step()
  expect.truthy(state.panel:find 'body/layout/menu', 'the trigger opens the menu')
  fixture.click(state, 'body/layout/menu/grid')
  state.fixture:step()
  expect.equal(chosen, 'grid')
  expect.equal(state.panel:find 'body/layout/menu', nil, 'choosing closes the menu')
  state.fixture:close()
end)

test('list rows report their ids, including ids with separators', function()
  local state = boot()
  local c = assert(state.components)
  local chosen = nil
  fixture.show(
    state,
    c.Panel {
      c.Body {
        key = 'body',
        c.List {
          key = 'plugins',
          items = { { id = 'desktop/backdrop', title = 'Backdrop' }, { id = 'desktop/keyboard', title = 'Keyboard' } },
          onChange = function(id: string)
            chosen = id
          end,
        },
      },
    }
  )
  fixture.click(state, 'body/plugins/desktop%2Fkeyboard')
  expect.equal(chosen, 'desktop/keyboard')
  state.fixture:close()
end)

test('a scroll box scrolls its content by dragging', function()
  local state = boot()
  local c = assert(state.components)
  local rows = {}
  for index = 1, 20 do
    rows[index] = c.Text { key = `row-{index}`, text = `Row {index}` }
  end
  fixture.show(
    state,
    c.Panel { c.Body { key = 'body', c.ScrollView { key = 'box', height = 0.1, c.Column { key = 'rows', rows } } } }
  )
  local first = assert(state.panel:find 'body/box/rows/row-1')
  local before = first:panelBounds().y
  drag(state, 'body/box', { 0.5, 0.8 }, { 0.5, 0.2 })
  state.fixture:step()
  local after = first:panelBounds().y
  expect.truthy(after < before - 0.03, `the content moved up: {before} to {after}`)
  state.fixture:close()
end)

test('a cancelled slider drag returns to the value prop', function()
  local state = boot()
  local c = assert(state.components)
  local changes: { number } = {}
  fixture.show(
    state,
    c.Panel {
      c.Body {
        key = 'body',
        c.Slider {
          key = 'level',
          label = 'Level',
          value = 0.2,
          onChange = function(value: number)
            table.insert(changes, value)
          end,
        },
      },
    }
  )
  local track = assert(state.panel:find 'body/level/track'):panelBounds()
  local surface = fixture.surface(state)
  local pointer = fixture.pointer()
  local y = track.y + track.height / 2
  local function deliver(kind: string, x: number?): ()
    surface:onPointer {
      kind = kind,
      pointer = pointer,
      x = x,
      y = if x then y else nil,
      button = 'left',
      captured = false,
      inside = true,
      reason = 'tracking-loss',
    }
  end
  deliver('enter', track.x + track.width * 0.2)
  deliver('press', track.x + track.width * 0.2)
  deliver('move', track.x + track.width * 0.8)
  state.fixture:step()
  local previewed = tonumber(assert(state.panel:find 'body/level/heading/value').props.text) :: number
  expect.truthy(previewed > 0.7, `the drag previews a higher value: {previewed}`)
  deliver 'cancel'
  state.fixture:step()
  expect.equal(assert(state.panel:find 'body/level/heading/value').props.text, '0.20', 'the cancel returns')
  expect.equal(changes[#changes], 0.2, 'the consumer hears the return')
  state.fixture:close()
end)

test('a scroll box scrolled past content that shrank shows the content from its top', function()
  local state = boot()
  local c = assert(state.components)
  local function show(count: number): ()
    local rows = {}
    for index = 1, count do
      rows[index] = c.Text { key = `row-{index}`, text = `Row {index}` }
    end
    fixture.show(
      state,
      c.Panel { c.Body { key = 'body', c.ScrollView { key = 'box', height = 0.1, c.Column { key = 'rows', rows } } } }
    )
  end
  show(30)
  local box = assert(state.panel:find 'body/box')
  box:setState { scrollY = 10 }
  state.fixture:step()
  show(3)
  state.fixture:step()
  local first = assert(state.panel:find 'body/box/rows/row-1'):panelBounds()
  expect.near(first.y, box:panelBounds().y, 1e-6, 'the first row is at the top of the box')
  state.fixture:close()
end)

test('a dropdown menu closes on a press outside it and opens past the panel edge', function()
  local state = fixture.boot { standard = true, width = 0.3, height = 0.09 }
  local c = assert(state.components)
  local options = {}
  for index = 1, 6 do
    options[index] = { id = `option-{index}`, label = `Option {index}` }
  end
  local presses = 0
  fixture.show(
    state,
    c.Panel {
      c.Body {
        key = 'body',
        c.Row {
          key = 'row',
          gap = 'sm',
          c.Dropdown { key = 'choice', value = 'option-1', options = options, grow = 1 },
          c.Button {
            key = 'other',
            label = 'Other',
            onActivate = function()
              presses += 1
            end,
          },
        },
      },
    }
  )
  fixture.click(state, 'body/row/choice/trigger')
  state.fixture:step()
  local last = assert(state.panel:find 'body/row/choice/menu/option-6', 'the menu is open')
  local _, height = state.panel:size()
  local panelPose = state.panel:pose()
  local _, panelY = panelPose:getPosition()
  local _, itemY = last:pose():getPosition()
  expect.truthy(math.abs(itemY - panelY) > height / 2, 'the menu reaches past the panel')
  fixture.click(state, 'body/row/other')
  state.fixture:step()
  expect.equal(presses, 1, 'the press outside reaches its target')
  expect.equal(state.panel:find 'body/row/choice/menu', nil, 'the menu closed')
  state.fixture:close()
end)

test('a dropdown at the bottom of a panel still opens its menu downward, past the panel edge', function()
  local state = fixture.boot { standard = true, width = 0.3, height = 0.24 }
  local c = assert(state.components)
  local options = {}
  for index = 1, 4 do
    options[index] = { id = `option-{index}`, label = `Option {index}` }
  end
  fixture.show(
    state,
    c.Panel {
      c.Body {
        key = 'body',
        c.Column { key = 'filler', height = 0.16 },
        c.Dropdown { key = 'choice', value = 'option-1', options = options },
      },
    }
  )
  fixture.click(state, 'body/choice/trigger')
  state.fixture:step()
  local first = assert(state.panel:find 'body/choice/menu/option-1', 'the menu is open')
  local trigger = assert(state.panel:find 'body/choice/trigger')
  local _, firstY = first:pose():getPosition()
  local _, triggerY = trigger:pose():getPosition()
  expect.truthy(firstY < triggerY, 'the menu opens below its trigger, though there is room above')
  state.fixture:close()
end)

test('a dropdown menu closes on a press at nothing', function()
  local state = fixture.boot { standard = true, width = 0.3, height = 0.09 }
  local c = assert(state.components)
  local options = { { id = 'one', label = 'One' }, { id = 'two', label = 'Two' } }
  fixture.show(
    state,
    c.Panel { c.Body { key = 'body', c.Dropdown { key = 'choice', value = 'one', options = options } } }
  )
  fixture.click(state, 'body/choice/trigger')
  state.fixture:step()
  expect.truthy(state.panel:find 'body/choice/menu/two', 'the menu is open')
  -- The ray points away from every panel, so the press lands on nothing.
  state.fixture:pose('right', lovr.math.newMat4():translate(10, 10, 0))
  state.fixture:step()
  state.fixture:button('right', 'trigger', true)
  state.fixture:step()
  state.fixture:button('right', 'trigger', false)
  state.fixture:step()
  state.fixture:step()
  expect.equal(state.panel:find 'body/choice/menu', nil, 'the menu closed')
  state.fixture:close()
end)

test('a ray press on a dropdown drags onto an item and chooses it on release', function()
  local state = fixture.boot { standard = true, width = 0.3, height = 0.09 }
  local c = assert(state.components)
  local chosen: { string } = {}
  local options = { { id = 'one', label = 'One' }, { id = 'two', label = 'Two' }, { id = 'three', label = 'Three' } }
  fixture.show(
    state,
    c.Panel {
      c.Body {
        key = 'body',
        c.Dropdown {
          key = 'choice',
          value = 'one',
          options = options,
          onChange = function(id: string)
            table.insert(chosen, id)
          end,
        },
      },
    }
  )
  local trigger = assert(state.panel:find 'body/choice/trigger')
  local controls = state.fixture
  controls:aim(fixture.nodeGeometry(trigger), 0.5, 0.5)
  controls:step()
  controls:button('right', 'trigger', true)
  controls:step()
  controls:step()
  local item = assert(state.panel:find 'body/choice/menu/three', 'the press opened the menu')
  controls:aim(fixture.nodeGeometry(item), 0.5, 0.5)
  controls:step()
  controls:step()
  controls:button('right', 'trigger', false)
  controls:step()
  controls:step()
  expect.equal(chosen[1], 'three', 'releasing over the item chooses it')
  expect.equal(state.panel:find 'body/choice/menu', nil, 'the menu closed')
  state.fixture:close()
end)

test('a handed-off press closes the menu when tracking is lost', function()
  local state = fixture.boot { standard = true, width = 0.3, height = 0.09 }
  local c = assert(state.components)
  local options = { { id = 'one', label = 'One' }, { id = 'two', label = 'Two' } }
  fixture.show(
    state,
    c.Panel { c.Body { key = 'body', c.Dropdown { key = 'choice', value = 'one', options = options } } }
  )
  local trigger = assert(state.panel:find 'body/choice/trigger')
  local controls = state.fixture
  controls:aim(fixture.nodeGeometry(trigger), 0.5, 0.5)
  controls:step()
  controls:button('right', 'trigger', true)
  controls:step()
  controls:step()
  expect.truthy(state.panel:find 'body/choice/menu/two', 'the press opened the menu')
  controls:tracked('right', false)
  for _ = 1, 3 do
    controls:step(0.1)
  end
  expect.equal(state.panel:find 'body/choice/menu', nil, 'losing the press closes the menu')
  state.fixture:close()
end)

test('releasing a dropdown press over its opener leaves the menu open for a separate click', function()
  local state = fixture.boot { standard = true, width = 0.3, height = 0.09 }
  local c = assert(state.components)
  local chosen: { string } = {}
  local options = { { id = 'one', label = 'One' }, { id = 'two', label = 'Two' } }
  fixture.show(
    state,
    c.Panel {
      c.Body {
        key = 'body',
        c.Dropdown {
          key = 'choice',
          value = 'one',
          options = options,
          onChange = function(id: string)
            table.insert(chosen, id)
          end,
        },
      },
    }
  )
  fixture.click(state, 'body/choice/trigger')
  state.fixture:step()
  expect.truthy(state.panel:find 'body/choice/menu/two', 'the menu stays open after the click')
  fixture.click(state, 'body/choice/menu/two')
  state.fixture:step()
  expect.equal(chosen[1], 'two', 'a separate click chooses the item')
  fixture.click(state, 'body/choice/trigger')
  state.fixture:step()
  fixture.click(state, 'body/choice/trigger')
  state.fixture:step()
  expect.equal(state.panel:find 'body/choice/menu', nil, 'a second click on the opener closes the menu')
  state.fixture:close()
end)

-- A virtual keyboard source, as the VR keyboard is, through the session's focus service.
local function keyboard(state: fixture.State): any
  local focusContract = require '@lunette-contracts/focus'
  local observed = assert(state.fixture.session):observe(focusContract.capability)
  local service = assert(observed.service)
  return service, service:newSource(assert(observed.context), { mode = 'virtual' })
end

test('pressing a text field takes the keyboard, and typing edits and submits it', function()
  local state = boot()
  local c = assert(state.components)
  local changes: { string } = {}
  local submitted: string? = nil
  fixture.show(
    state,
    c.Panel {
      c.Body {
        key = 'body',
        c.TextField {
          key = 'name',
          value = '',
          placeholder = 'Name',
          onChange = function(value: string)
            table.insert(changes, value)
          end,
          onSubmit = function(value: string)
            submitted = value
          end,
        },
      },
    }
  )
  local focusService, source = keyboard(state)
  fixture.click(state, 'body/name')
  state.fixture:step()
  local focused = focusService:focused()
  expect.truthy(focused, 'the field took session focus')
  local codes = require('@lunette-contracts/keys').CODES
  expect.equal(source:text('héllo').kind, 'consumed')
  expect.equal(changes[#changes], 'héllo')
  source:key { code = codes.backspace }
  expect.equal(changes[#changes], 'héll')
  source:key { code = codes.home }
  source:text 'a '
  expect.equal(changes[#changes], 'a héll')
  state.fixture:step()
  local text = assert(state.panel:find 'body/name/face/text')
  expect.equal(text.props.value, 'a héll', 'the field shows its draft')
  source:key { code = codes.enter }
  expect.equal(submitted, 'a héll')
  state.fixture:close()
end)

test('a focused text field keeps its caret through echoes and takes a reset from outside', function()
  local state = boot()
  local c = assert(state.components)
  local value = ''
  local function render(): ()
    fixture.show(
      state,
      c.Panel {
        c.Body {
          key = 'body',
          c.TextField {
            key = 'name',
            value = value,
            onChange = function(changed: string)
              value = changed
            end,
          },
        },
      }
    )
  end
  render()
  local _, source = keyboard(state)
  fixture.click(state, 'body/name')
  state.fixture:step()
  local codes = require('@lunette-contracts/keys').CODES
  source:text 'abc'
  source:key { code = codes.left }
  render()
  local text = assert(state.panel:find 'body/name/face/text')
  expect.equal(text.props.value, 'abc', 'the echoed value shows')
  expect.equal(text.props.caret, 3, 'the caret stays where the edit left it')
  value = ''
  render()
  text = assert(state.panel:find 'body/name/face/text')
  expect.equal(text.props.value, '', 'a reset from outside replaces the draft while focused')
  source:text 'z'
  expect.equal(value, 'z', 'typing continues from the reset value')
  state.fixture:close()
end)

test('rows and columns take a minimum and maximum height', function()
  local state = boot()
  local c = assert(state.components)
  fixture.show(
    state,
    c.Panel {
      c.Body {
        key = 'body',
        c.Row { key = 'tall', minHeight = 0.08, c.Text { key = 'text', text = 'Short' } },
        c.Column {
          key = 'capped',
          maxHeight = 0.02,
          c.Spacer { key = 'filler', height = 0.05, grow = 0 },
        },
      },
    }
  )
  expect.near(assert(state.panel:find 'body/tall').bounds.height, 0.08, 1e-6, 'the row reaches its minimum')
  expect.near(assert(state.panel:find 'body/capped').bounds.height, 0.02, 1e-6, 'the column stops at its maximum')
  state.fixture:close()
end)

test('traversal moves focus through controls and activates the focused one', function()
  local state = boot()
  local c = assert(state.components)
  local activated: { string } = {}
  local function button(key: string): any
    return c.Button {
      key = key,
      label = key,
      onActivate = function()
        table.insert(activated, key)
      end,
    }
  end
  fixture.show(
    state,
    c.Panel { c.Body { key = 'body', c.Row { key = 'row', button 'first', button 'second', button 'third' } } }
  )
  local host = state.service
  expect.truthy(host:nextPanel(), 'traversal enters the panel')
  state.fixture:step()
  expect.truthy(host:activate())
  expect.truthy(host:navigate 'right')
  expect.truthy(host:navigate 'next')
  expect.truthy(host:activate())
  expect.equal(table.concat(activated, ','), 'first,third')
  local third = assert(state.panel:find 'body/row/third/face')
  expect.truthy(third.state.focusVisible, 'focus from traversal shows a ring')
  state.fixture:close()
end)

test('an engaged slider takes directions from a controller, and an idle one passes them on', function()
  local state = boot()
  local c = assert(state.components)
  local value = 0.5
  fixture.show(
    state,
    c.Panel {
      c.Body {
        key = 'body',
        c.Slider {
          key = 'level',
          label = 'Level',
          value = value,
          step = 0.1,
          onCommit = function(next: number)
            value = next
          end,
        },
        c.Button { key = 'after', label = 'After', onActivate = function() end },
      },
    }
  )
  local host = state.service
  expect.truthy(host:nextPanel())
  state.fixture:step()
  expect.truthy(host:navigate 'right' == false, 'an idle slider passes the direction on, and nothing lies right')
  expect.near(value, 0.5, 1e-9, 'the value is unchanged')
  expect.truthy(host:navigate 'down', 'focus moves to the button below')
  expect.truthy(host:navigate 'up')
  expect.truthy(host:activate(), 'activation engages the slider')
  expect.truthy(host:navigate 'right')
  expect.near(value, 0.6, 1e-9, 'the engaged slider moved')
  expect.truthy(host:dismiss(), 'dismissal disengages it')
  state.fixture:close()
end)

test('controls are found by role and name, and inspection reports their semantics', function()
  local state = boot()
  local c = assert(state.components)
  local applied = 0
  fixture.show(
    state,
    c.Panel {
      c.Body {
        key = 'body',
        c.Toggle { key = 'backdrop', label = 'Backdrop', value = true, onChange = function() end },
        c.Button {
          key = 'apply',
          label = 'Apply',
          onActivate = function()
            applied += 1
          end,
        },
        c.Button { key = 'pin', label = 'Pin', disabledReason = 'Pinning needs the Attention source.' },
      },
    }
  )
  local apply = assert(state.service:findByRole('button', 'Apply'), 'the button is found by role and name')
  state.fixture:click(fixture.nodeGeometry(apply), 0.5, 0.5)
  expect.equal(applied, 1)
  expect.equal(state.service:findByRole('button', 'Missing'), nil)
  local byId: { [string]: any } = {}
  for _, registration in state.service:inspectNodes().registrations do
    if registration.kind == 'control' then
      byId[registration.name or ''] = registration.details
    end
  end
  local toggle = assert(byId['host-test:body/backdrop'], 'the toggle is reported by id')
  expect.equal(toggle.role, 'switch')
  expect.equal(toggle.checked, true)
  expect.equal(toggle.label, 'Backdrop')
  local pin = assert(byId['host-test:body/pin'])
  expect.equal(pin.enabled, false)
  expect.equal(pin.disabledReason, 'Pinning needs the Attention source.')
  state.fixture:close()
end)

test('a tap on a slider track moves the value to the tap', function()
  local state = boot()
  local c = assert(state.components)
  local committed: number? = nil
  fixture.show(
    state,
    c.Panel {
      c.Body {
        key = 'body',
        c.Slider {
          key = 'level',
          label = 'Level',
          value = 0.1,
          onCommit = function(value: number)
            committed = value
          end,
        },
      },
    }
  )
  local track = assert(state.panel:find 'body/level/track')
  local bounds = track:panelBounds()
  local geometry = fixture.geometry(state)
  state.fixture:click(geometry, bounds.x + bounds.width * 0.8, bounds.y + bounds.height / 2)
  assert(committed, 'the tap committed a value')
  expect.truthy(committed > 0.7 and committed < 0.9, `the value follows the tap: {committed}`)
  state.fixture:close()
end)

test('a slider can settle just beside a detent, drawn towards it but not onto it', function()
  local state = boot()
  local c = assert(state.components)
  local changes, commits = {}, {}
  fixture.show(
    state,
    c.Panel {
      c.Body {
        key = 'body',
        c.Slider {
          key = 'response',
          label = 'Response',
          value = 0,
          detents = { { value = 0, label = 'None' }, { value = 0.5, label = 'Medium' }, { value = 1, label = 'Full' } },
          onChange = function(value: number)
            table.insert(changes, value)
          end,
          onCommit = function(value: number)
            table.insert(commits, value)
          end,
        },
      },
    }
  )
  drag(state, 'body/response/track', { 0.3, 0.5 }, { 0.54, 0.5 })
  local released = commits[1]
  expect.truthy(released > 0.5 and released < 0.54, `the value is drawn towards Medium but stays beside it: {released}`)
  expect.equal(changes[#changes - 1], released, 'the release keeps the value shown while dragging')
  state.fixture:close()
end)

test('a scroll box scrolls by its thumb, its track, and its content', function()
  local state = boot()
  local c = assert(state.components)
  fixture.show(
    state,
    c.Panel {
      c.Body {
        key = 'body',
        c.ScrollView {
          key = 'box',
          height = 0.1,
          c.Column { key = 'tall', height = 0.4 },
        },
      },
    }
  )
  state.fixture:step()
  local box = assert(state.panel:find 'body/box')
  local limit = 0.4 - box.bounds.height
  local edge = 1 - 0.2 * scrollingGutter(state) / box.bounds.width
  -- The thumb starts at the top; dragging it to the bottom of the track scrolls to the end.
  drag(state, 'body/box', { edge, 0.05 }, { edge, 1.2 })
  expect.near(box.state.scrollY, limit, 1e-3, 'the thumb drag reaches the end')
  -- Dragging the content down moves it with the pointer, back towards the start.
  drag(state, 'body/box', { 0.3, 0.2 }, { 0.3, 0.7 })
  expect.near(box.state.scrollY, limit - box.bounds.height * 0.5, 0.01, 'the content follows the pointer')
  -- A click on the track above the thumb brings the thumb there.
  drag(state, 'body/box', { edge, 0.02 }, { edge, 0.02 })
  expect.near(box.state.scrollY, 0, 1e-3, 'the track click jumps to the top')
  state.fixture:close()
end)

test('a virtual list of thousands keeps only the rows near its visible part, and scrolls to any of them', function()
  local state = boot()
  local c = assert(state.components)
  local chosen: number? = nil
  fixture.show(
    state,
    c.Panel {
      c.Body {
        key = 'body',
        c.ScrollView {
          key = 'many',
          count = 5000,
          rowHeight = 0.03,
          height = 0.15,
          renderItem = function(index: number): any
            return c.ListRow {
              key = 'row',
              title = `Entry {index}`,
              onActivate = function()
                chosen = index
              end,
            }
          end,
        },
      },
    }
  )
  state.fixture:step()
  local list = assert(state.panel:find 'body/many')
  local materialised = 0
  for index = 1, 40 do
    if state.panel:find(`body/many/row-{index}`) then
      materialised += 1
    end
  end
  expect.truthy(materialised > 0 and materialised < 20, `a few rows exist: {materialised}`)
  expect.equal(state.panel:find 'body/many/row-4000', nil, 'distant rows do not exist')
  list:setState { scrollY = 0.03 * 3999 }
  state.fixture:step()
  state.fixture:step()
  local far = assert(state.panel:find 'body/many/row-4000/row', 'scrolling materialises the row')
  state.fixture:click(fixture.nodeGeometry(far), 0.5, 0.5)
  expect.equal(chosen, 4000)
  state.fixture:close()
end)

return test

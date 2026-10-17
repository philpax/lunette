local testing = require '@testing'
local fixture = require '@testing/ui-host'
local expect = testing.expect
local test = testing.suite()

local CONTROLS = {
  { name = 'Button', target = 'face', text = 'face/label', visual = 'lunette/text', callback = 'onActivate' },
  { name = 'Chip', target = 'face', text = 'face/label', visual = 'lunette/text', callback = 'onChange' },
  { name = 'Toggle', target = 'row', text = 'row/text/label', visual = 'lunette/text', callback = 'onChange' },
  { name = 'Checkbox', target = 'row', text = 'row/text/label', visual = 'lunette/text', callback = 'onChange' },
  { name = 'Slider', target = 'track', text = 'heading/label', visual = 'lunette/text', callback = 'onChange' },
  { name = 'TextField', target = '', text = 'face/text', visual = 'lunette/field-text', callback = 'onChange' },
}

for _, control in CONTROLS do
  for _, disabling in { 'disabled', 'disabledReason' } do
    test(`{control.name} propagates {disabling} to pointer input, traversal, semantics, and its text`, function()
      local state = fixture.boot { standard = true, width = 0.4, height = 0.4 }
      local c = assert(state.components)
      local changes = 0
      local after = 0
      local color = nil
      state.service:registerVisual(state.owner, control.visual, function(node: any, draw: any, base: any)
        if node == state.panel:find(`body/control/{control.text}`) then
          local proxy = setmetatable({
            text = function(_self: any, options: any): any
              color = options.color
              return draw:text(options)
            end,
          }, { __index = draw })
          base(node, proxy)
        else
          base(node, draw)
        end
      end)
      local function show(disabled: boolean): ()
        local props: { [string]: any } = {
          key = 'control',
          [control.callback] = function()
            changes += 1
          end,
        }
        if control.name == 'TextField' then
          props.value = 'Text'
        else
          props.label = control.name
          if control.name ~= 'Button' and control.name ~= 'Chip' then
            props.value = if control.name == 'Slider' then 0.5 else false
          end
        end
        if disabled then
          props[disabling] = if disabling == 'disabled' then true else 'Unavailable.'
        end
        fixture.show(
          state,
          c.Panel {
            c.Body {
              key = 'body',
              c.Button { key = 'before', label = 'Before', onActivate = function() end },
              c[control.name](props),
              c.Button {
                key = 'after',
                label = 'After',
                onActivate = function()
                  after += 1
                end,
              },
            },
          }
        )
      end
      show(true)
      local path = 'body/control' .. (if control.target == '' then '' else '/' .. control.target)
      fixture.click(state, path)
      expect.equal(changes, 0, 'a pointer cannot change a disabled control')
      if disabling == 'disabledReason' and control.name == 'Button' then
        state.fixture:step()
        expect.truthy(state.panel:find 'body/control/reason', 'hover still shows the reason')
      elseif disabling == 'disabled' and control.name == 'Button' then
        expect.equal(state.panel:find 'body/control/reason', nil, 'boolean disabling adds no reason')
      elseif disabling == 'disabledReason' and (control.name == 'Toggle' or control.name == 'Checkbox') then
        expect.equal(assert(state.panel:find 'body/control/row/text/reason').props.text, 'Unavailable.')
      end
      local semantics = state.service:inspectNodes()
      local described = false
      for _, item in semantics.registrations do
        if item.name == 'host-test:body/control' then
          expect.equal(item.details.enabled, false, 'inspection reports the control as disabled')
          described = true
        end
      end
      expect.truthy(described, 'inspection includes the composite')
      local target = assert(state.panel:find(path))
      expect.equal(target:focus(), false, 'the interactive child refuses focus')
      expect.truthy(state.service:nextPanel(), 'controller traversal enters the panel')
      expect.truthy(state.service:navigate 'next', 'controller traversal skips the disabled control')
      expect.truthy(assert(state.panel:find 'body/after/face').state.focused, 'the following button holds focus')
      expect.truthy(state.service:activate())
      expect.equal(after, 1, 'controller activation reaches the following button')
      expect.equal(changes, 0, 'controller activation cannot change the disabled control')
      state.fixture:draw()
      expect.equal(color, state.service:theme().colors.muted, 'disabled text uses the muted colour')
      show(false)
      expect.truthy(assert(state.panel:find(path)):focus(), 'clearing the disabling prop restores focus')
      if control.name == 'TextField' then
        local focus = require '@lunette-contracts/focus'
        local observed = assert(state.fixture.session):observe(focus.capability)
        local source = assert(observed.service):newSource(assert(observed.context), { mode = 'virtual' })
        source:text 'x'
      elseif control.name == 'Slider' then
        expect.truthy(state.service:activate(), 'activation engages the enabled slider')
        expect.truthy(state.service:navigate 'right', 'controller input changes the enabled slider')
      else
        fixture.click(state, path)
      end
      expect.truthy(changes > 0, 'the enabled control still reports changes')
      state.fixture:close()
    end)
  end
end

return test

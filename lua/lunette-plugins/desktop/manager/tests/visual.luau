local testing = require '@testing'
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local builtIn = require '@lunette-plugins/ui'
local render = require '@testing/render'
local schema = require '@lunette-plugin/schema'
local base = require '@lunette-plugins/theme/base'
local boot = require './support/boot'
local expect = testing.expect
local test = testing.suite()

local function observer(provider, recorded)
  return plugin.define {
    name = 'testing/manager-visual-ui',
    requires = provider.requires,
    provides = { ui = ui.capability },
    init = function(context, _, publish)
      local service = provider.build(context)
      local function hook(original)
        return function(pass, visual, base)
          local first = #recorded.calls + 1
          local checkpoint = recorded:checkpoint()
          if original then
            original(pass, visual, base)
          else
            base(pass, visual)
          end
          recorded.visuals[#recorded.visuals + 1] = {
            visual = visual,
            first = first,
            last = #recorded.calls,
            frame = checkpoint.transform,
          }
        end
      end
      publish:provide(ui.capability, {
        newPanel = function(_, owner, given)
          local options = table.clone(given)
          options.draw = hook(options.draw)
          local panel = service:newPanel(owner, options)
          return setmetatable({}, {
            __index = function(_, key)
              if key == 'region' then
                return function(_, controlOwner, supplied)
                  local control = table.clone(supplied)
                  control.draw = hook(control.draw)
                  return panel:region(controlOwner, control)
                end
              end
              local value = panel[key]
              return if type(value) == 'function'
                then function(_, ...)
                  return value(panel, ...)
                end
                else value
            end,
          })
        end,
        panels = function()
          return service:panels()
        end,
      })
    end,
  }
end

local function background(call, state)
  if call[1] ~= 'plane' or call[5] ~= state.sidebar or call[6] ~= state.height then
    return false
  end
  local color = call.state.setColor
  local expected = base.colors.elevatedBackground
  return color and color[1][1] == expected[1] and color[1][2] == expected[2] and color[1][3] == expected[3]
end

test('sidebar renders once before shared controls and every hook respects its clip', function()
  local recorder = render.new()
  recorder.visuals = {}
  local editable = plugin.consumer({
    name = 'visual-editable',
    schema = schema.object {
      title = schema.default(schema.string()) 'Visible draft',
      enabled = schema.default(schema.boolean())(true),
    },
    init = function() end,
  }).definition
  local marker = 'VISUAL_DIAGNOSTIC_TAIL'
  local failed = plugin.define {
    name = 'visual-failure',
    init = function()
      error(string.rep('diagnostic words ', 80) .. '\n' .. marker, 0)
    end,
  }
  local running, fake, _, state, _, public = boot({ visible = true }, {
    { id = 'ui', definition = observer(builtIn, recorder) },
    { id = 'visual-editable', definition = editable },
    { id = 'visual-failure', definition = failed },
  })
  testing.takeReports()
  lovr.graphics.getDefaultFont = function()
    return recorder.font
  end
  local ok, problem = pcall(function()
    local pointer = public:pointer()
    public:click(pointer, 'fit')
    public:click(pointer, 'graph', 'visual-editable')
    for _, tab in { 'inspect', 'configure', 'catalog' } do
      public:click(pointer, tab)
      if tab == 'configure' then
        public:click(pointer, 'rows', 'row/s:title')
      end
      table.clear(recorder.calls)
      table.clear(recorder.visuals)
      public:panel():draw(recorder.pass)
      local count, backgroundIndex = 0, nil
      for index, call in recorder.calls do
        if background(call, state) then
          count += 1
          backgroundIndex = index
        end
      end
      expect.equal(count, 1, tab .. ' draws the opaque sidebar background once')
      local widgetFirst, widgetCount = nil, 0
      for _, entry in recorder.visuals do
        if entry.visual.kind == 'button' and entry.visual.id == 'configure' then
          widgetFirst = entry.first
          widgetCount += 1
        end
      end
      expect.equal(widgetCount, 1, 'the shared sidebar widget renders once')
      expect.truthy(
        widgetFirst and backgroundIndex < widgetFirst,
        'the sidebar widget renders after the opaque background'
      )
      for _, entry in recorder.visuals do
        local last = entry.last
        if entry.visual.kind ~= 'panel' then
          recorder:assertBounds(entry.visual.clip, entry.first, last, entry.frame)
        end
      end
      if tab == 'configure' then
        local field, content = nil, false
        for _, entry in recorder.visuals do
          if entry.visual.id == 'edit-field' then
            field = entry
            for index = entry.first, entry.last do
              local call = recorder.calls[index]
              if call[1] == 'text' and call[2]:find('Visible draft', 1, true) then
                content = true
              end
            end
          end
        end
        expect.truthy(field and field.first > backgroundIndex, 'the shared draft field stays above the background')
        expect.truthy(content, 'the shared field draws the current draft')
      end
      recorder:assertRestored()
    end
    public:click(pointer, 'inspect')
    public:click(pointer, 'fit')
    public:click(pointer, 'graph', 'visual-failure')
    local seen = false
    for _ = 1, 150 do
      table.clear(recorder.calls)
      table.clear(recorder.visuals)
      public:panel():draw(recorder.pass)
      for _, entry in recorder.visuals do
        if entry.visual.kind ~= 'panel' then
          recorder:assertBounds(entry.visual.clip, entry.first, entry.last, entry.frame)
        end
      end
      for _, call in recorder.calls do
        if call[1] == 'text' and call[2]:find(marker, 1, true) then
          seen = true
        end
      end
      if seen then
        break
      end
      local x, y = public:point 'details'
      public:update(pointer, x, y, { scrollY = -1 })
    end
    expect.truthy(seen, 'public detail scrolling reaches the rich diagnostic tail')
    recorder:assertRestored()
  end)
  local closed, cleanup = pcall(function()
    running.runtime:close()
    fake.assertResourcesReleased()
  end)
  if not ok then
    error(tostring(problem) .. (if closed then '' else '\ncleanup: ' .. tostring(cleanup)), 0)
  end
  if not closed then
    error(cleanup, 0)
  end
end)
test('graph notices render inside the nonzero-origin production region', function()
  local recorder = render.new()
  recorder.visuals = {}
  local running, fake, _, _, _, public = boot({ visible = true }, {
    { id = 'ui', definition = observer(builtIn, recorder) },
  })
  lovr.graphics.getDefaultFont = function()
    return recorder.font
  end
  local ok, problem = pcall(function()
    local pointer = public:pointer()
    local function notice(expected)
      table.clear(recorder.calls)
      table.clear(recorder.visuals)
      public:panel():draw(recorder.pass)
      local found = false
      for _, entry in recorder.visuals do
        if entry.visual.id == 'graph' then
          expect.truthy(entry.visual.clip.y > 0, 'the graph starts below the shared toolbar')
          recorder:assertBounds(entry.visual.clip, entry.first, entry.last, entry.frame)
          for index = entry.first, entry.last do
            local call = recorder.calls[index]
            if call[1] == 'text' and call[2]:find(expected, 1, true) then
              found = true
            end
          end
        end
      end
      expect.truthy(found, 'the graph renders its notice: ' .. expected)
      recorder:assertRestored()
    end
    public:click(pointer, 'fit')
    local bounds = public:control('graph').bounds
    local x, y = bounds.x + 1, bounds.y + bounds.height / 2
    public:update(pointer, x, y, { buttons = { left = true } })
    public:update(pointer, x + 100000, y + 100000, { buttons = { left = true } })
    public:update(pointer, x + 100000, y + 100000)
    notice 'plugins outside the canvas'
    public:click(pointer, 'fit')
    public:click(pointer, 'search')
    local source = public:source()
    source:text 'UNMATCHED_VISUAL_GRAPH_FILTER'
    lovr.update(0)
    notice 'No plugins match the current filter.'
  end)
  local closed, cleanup = pcall(function()
    running.runtime:close()
    fake.assertResourcesReleased()
  end)
  if not ok then
    error(tostring(problem) .. (if closed then '' else '\ncleanup: ' .. tostring(cleanup)), 0)
  end
  if not closed then
    error(cleanup, 0)
  end
end)

return test

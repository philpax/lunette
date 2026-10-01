-- plugin.options merges a configuration over defaults and names what it rejects;
-- plugin.merge applies the same rule without validating.
return function(plugin)
  local function raises(expected, run)
    local ok, message = pcall(run)
    assert(not ok, 'expected an error naming ' .. expected)
    assert(tostring(message):find(expected, 1, true), 'expected ' .. expected .. ', got ' .. tostring(message))
  end
  local defaults = {
    style = { length = 1, color = { 0, 0, 1, 1 }, inner = { depth = 2 } },
    count = 3,
    hook = function() end,
    empty = {},
  }
  local function resolve(config)
    return plugin.options { name = 'probe', defaults = defaults, config = config }
  end

  -- No configuration answers a frozen copy of the defaults, a fresh one each
  -- time, so no two activations share one.
  local first, second = resolve(nil), resolve(nil)
  assert(first ~= second and first.style ~= defaults.style and first.style.length == 1)
  assert(table.isfrozen(first) and table.isfrozen(first.style) and table.isfrozen(first.style.color))
  assert(not table.isfrozen(defaults), 'the defaults are not changed')

  -- A record merges key by key at every depth; a list, a function, and an
  -- empty table replace.
  local configs = {
    {},
    { count = 4 },
    { style = { length = 2 } },
    { style = { color = { 1 } } },
    { style = { inner = { depth = 5 } }, count = 0 },
    { empty = { 1, 2 } },
    {
      hook = function()
        return 1
      end,
    },
  }
  for _, config in ipairs(configs) do
    local resolved = resolve(config)
    for key, value in defaults do
      local given = config[key]
      if given == nil then
        assert(resolved[key] == value or type(value) == 'table', key .. ' keeps its default')
      end
    end
    -- Resolving is idempotent: a resolved configuration resolves to itself.
    local again = resolve(resolved)
    assert(again.count == resolved.count and again.style.length == resolved.style.length)
    assert(#again.style.color == #resolved.style.color and again.style.inner.depth == resolved.style.inner.depth)
    assert(#again.empty == #resolved.empty and again.hook == resolved.hook)
  end
  local nested = resolve { style = { inner = { depth = 5 } } }
  assert(nested.style.inner.depth == 5 and nested.style.length == 1 and nested.style.color[3] == 1)
  local list = resolve { style = { color = { 1 } } }
  assert(#list.style.color == 1)

  raises('plugin probe: unknown option style.inner.width; the options are depth', function()
    resolve { style = { inner = { width = 1 } } }
  end)
  raises('plugin probe: unknown option colour; the options are count, empty, hook, style', function()
    resolve { colour = 1 }
  end)
  raises('plugin probe: option count is a number, not a string', function()
    resolve { count = 'three' }
  end)
  raises('plugin probe: option style is a table, not a number', function()
    resolve { style = 1 }
  end)
  raises('plugin probe: unknown option 1', function()
    resolve { 1 }
  end)
  raises('plugin probe: the configuration is a table of options, not a boolean', function()
    resolve(true)
  end)
  raises('plugin bare: unknown option x; bare takes no options', function()
    plugin.options { name = 'bare', defaults = {}, config = { x = 1 } }
  end)

  -- merge follows the same rule without validating, and changes neither side.
  local base = { style = { length = 1, color = { 0, 0, 1 } }, extra = true }
  local over = { style = { color = { 1 } }, added = 2 }
  local merged = plugin.merge { base = base, over = over }
  assert(merged.style.length == 1 and #merged.style.color == 1 and merged.extra and merged.added == 2)
  assert(#base.style.color == 3 and over.style.length == nil)
  assert(next(plugin.merge {}) == nil)
end

local plugin = require '@lunette-plugin'
local panels = require '@lunette-contracts/panels'
local tags = require '@lunette-contracts/tags'
local rules = require '@lunette-contracts/rules'
local layout = require '@lunette-contracts/layout'
local runtime = plugin.runtime()
for _, name in ipairs { 'panels', 'tags', 'rules', 'layout/arc' } do
  runtime:use(require('@lunette-plugins/' .. name), {}):enable()
end
local owner, services
local consumer = runtime:use(
  plugin.define(
    function(value)
      return value
    end,
    { panels = panels.capability, tags = tags.capability, rules = rules.capability, arc = layout.arc },
    {},
    function(context)
      owner = context
      services = {
        panels = context:require(panels.capability),
        tags = context:require(tags.capability),
        rules = context:require(rules.capability),
        arc = context:require(layout.arc),
      }
    end
  ),
  {}
)
consumer:enable()
assert(services, 'consumer activated')
local literal = function()
  error 'literal extension called'
end
local extension = { nested = { 1, 2 } }
assert(services.rules:matches({
  appId = function(value, source)
    return value == source.appId
  end,
  opaque = false,
}, window))
assert(services.rules:matches({
  title = function(value)
    return value == nil
  end,
}, { title = nil }))
assert(not pcall(function()
  services.rules:matches({ typo = true }, window)
end))
local low = services.rules:addSource(owner, 'typed-low', 10, function()
  return {
    width = function()
      error 'overwritten named evaluator called'
    end,
    chrome = function()
      return false
    end,
    callback = literal,
    payload = extension,
    evaluate = {
      dynamic = function()
        error 'overwritten extension evaluator called'
      end,
      kept = function(_, key)
        return key
      end,
    },
  }
end)
local high = services.rules:addSource(owner, 'typed-high', 20, function()
  return {
    width = function(source, key)
      assert(key == 'width')
      return source.width / 400
    end,
    dynamic = false,
  }
end)
local typed = services.rules:resolve(window)
assert(typed.width == 2 and typed.chrome == false and typed.dynamic == false)
assert(typed.callback == literal and typed.payload == extension and typed.kept == 'kept' and typed.evaluate == nil)
low:dispose()
high:dispose()
local invalid = services.rules:addSource(owner, 'invalid-evaluator', 10, function()
  return { evaluate = {
    width = function()
      return 'invalid'
    end,
  } }
end)
assert(not pcall(function()
  services.rules:resolve(window)
end))
invalid:dispose()
local tag = services.tags:new(owner, 'primary', { selected = true })
assert(tag.selected)
assert(tag:setSelected(false) and not tag.selected)
assert(tag:setSelected(true))
local weakTags = setmetatable({}, { __mode = 'v' })
for index = 1, 12 do
  do
    local temporary = services.tags:new(owner, 'temporary-' .. index)
    weakTags[1] = temporary
    assert(temporary:destroy())
    assert(not temporary:destroy())
  end
  collectgarbage()
  collectgarbage()
  assert(weakTags[1] == nil, 'destroyed tag retained by active owner')
end
local oldPayloads = setmetatable({}, { __mode = 'v' })
local function sourceWithPayload(slot: number)
  local payload = { marker = true }
  oldPayloads[slot] = payload
  return services.rules:addSource(owner, 'same', 100, function()
    assert(payload.marker)
    return { width = 2 }
  end)
end
for cycle = 1, 12 do
  do
    local first = sourceWithPayload(cycle)
    local replacement = services.rules:addSource(owner, 'same', 100, function()
      return { width = cycle, tags = { 'primary', 'implicit' } }
    end)
    first:dispose()
    first:dispose()
    collectgarbage()
    collectgarbage()
    assert(oldPayloads[cycle] == nil, 'replaced source payload retained by active owner')
    local registered = services.rules:sources()[1]
    assert(registered.name == 'same' and registered.precedence == 100)
    assert(#services.rules:sources() == 1)
    replacement:dispose()
    assert(#services.rules:sources() == 0)
  end
end
local first = sourceWithPayload(13)
local second = services.rules:addSource(owner, 'same', 100, function()
  return { width = 3, tags = { 'primary', 'implicit' } }
end)
first:dispose()
collectgarbage()
collectgarbage()
assert(oldPayloads[13] == nil, 'replaced source payload retained by active owner')
local registered = services.rules:sources()[1]
assert(registered.name == 'same' and registered.precedence == 100)
assert(#services.rules:sources() == 1)
local panel, resolved = services.rules:place(owner, window, { height = 1, chrome = false })
assert(resolved.width == 3 and panel.width == 3 and panel.height == 1)
assert(tag:has(panel) and not tag:add(panel))
assert(#services.tags:panelsOf { tag, services.tags:find 'implicit' } == 1)
services.arc:apply(tag)
assert(panel.pose.x == 0 and panel.pose.y == 1.5 and panel.pose.z == -1.6)
for count = 0, 20 do
  local angles = services.arc:angles(count)
  assert(#angles == count)
  for index, angle in ipairs(angles) do
    assert(math.abs(angle + angles[count + 1 - index]) < 1e-12)
  end
end
local before = #services.panels:all()
local stranger = runtime:use(
  plugin.define(function(value)
    return value
  end, {}, {}, function(context)
    assert(not pcall(function()
      services.rules:place(context, window)
    end))
    assert(not pcall(function()
      services.tags:new(context, 'forbidden')
    end))
  end),
  {}
)
stranger:enable()
assert(#services.panels:all() == before and not services.tags:find 'forbidden')
second:dispose()
assert(#services.rules:sources() == 0)
lovr.log = function()
  error 'injected report failure'
end
assert(not pcall(function()
  services.rules:place(owner, window, { tags = { 'rollback' } })
end))
lovr.log = nil
assert(#services.panels:all() == before, 'rollback panel count: ' .. #services.panels:all() .. ' expected ' .. before)
assert(not services.tags:find 'rollback')
assert(claims[#claims].dead)
assert(panel:destroy() and not panel:destroy())
assert(not services.tags:find 'implicit', 'destroying a rules panel must release its implicit tag')
assert(services.tags:find 'primary' == tag and not tag.dead)
assert(#tag.members == 0, 'destroying a rules panel must remove its membership immediately')
consumer:disable()
assert(panel.dead and tag.dead and claims[1].dead)
assert(#services.panels:all() == 0 and #services.tags:all() == 0)
runtime:close()

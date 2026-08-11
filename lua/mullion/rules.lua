-- Rules: what a window should look like, decided before anything draws it.
--
-- docs/stdlib.md's tier 3, the part that decides where a window goes. The
-- minimum-viable line asks for a rules table matched on `appId`, and this is it,
-- plus the composition that Task 10's saved arrangement needs to sit alongside
-- it rather than inside it.
--
-- The shape is awesome's and none of its code: awesome is GPL-2 and lunette
-- GPL-3-only (docs/decisions.md), so nothing was copied and its source was not
-- consulted while this was written. What was taken is a design, which is not
-- copyrightable — a flat ordered list of match-and-properties tables, and a
-- matcher that composes several *sources* with a declared precedence.
--
-- The precedence is the load-bearing part. Restore-on-startup and
-- apply-rules-on-open answer the same question about the same window and want
-- different answers: a window that was hand-placed should come back where it
-- was, and a window opening fresh should be placed by rule. Collapsing them into
-- one list makes one of those cases wrong, and which one depends on the order
-- the configuration happened to write its entries in. As sources, the
-- configuration says which wins.
--
-- This module takes no `lovr.lun*` callback. The callback namespace belongs to
-- the configuration (docs/stdlib.md), so `lovr.lunwindowopened` calls `place`
-- rather than this module taking the callback out from under it.

local panel = require 'mullion.panel'
local pose = require 'mullion.pose'
local tag = require 'mullion.tag'
local teardown = require 'mullion.teardown'

local rules = {}

-- Declared here and defined below the public API, so the file reads
-- surface-first.
local byPrecedence, layer, evaluate, applyTags, poseFrom

-- Every source, as `{ { name, precedence, resolve, sequence } }` in registration
-- order.
--
-- Rebuilt when this file runs, so a soft reload that re-runs the configuration
-- starts from no sources rather than from the old state's.
type Source = {
  name: string,
  precedence: number,
  resolve: (window: any) -> { [string]: any } | nil,
  sequence: number,
}
local sources: { Source } = {}

-- How many sources have ever been registered, which is the tiebreak between two
-- at the same precedence.
local registrations = 0

-- Where `setRules` registers the configuration's own rules table.
--
-- A round number with room either side, so that a source meant to run before or
-- after it can be given a precedence without the numbers having to be renegotiated.
rules.DEFAULT_PRECEDENCE = 100

-- The name `setRules` registers under.
rules.DEFAULT_SOURCE = 'mullion.rules'

-- The panel options `place` takes out of a resolved property table.
--
-- Everything else in the table is handed back to the caller untouched: a
-- properties table is an open bag, and a rule setting a key this module has
-- never heard of is a configuration talking to itself rather than a defect.
rules.PANEL_PROPERTIES = { 'pose', 'width', 'height', 'title', 'priority', 'chrome' }

-- Where a rule that could not be honoured is reported.
--
-- Replaceable, so that Phase 7's error handling can route it wherever it routes
-- everything else, and so that a spec can capture it rather than printing it.
-- The default logs the message, which the host routes to its own diagnostics.
--
-- `level` carries a LÖVR log level and defaults to `warn`, because most of what
-- reaches here is a rule the configuration wrote that could not be honoured. A
-- tag created on demand is the exception: that is the documented behaviour
-- rather than a mistake, so it reports at `info`.
function rules.report(message: string, level: string?)
  lovr.log(message, level or 'warn', 'mullion.rules')
end

-- Registers `resolve` as a source under `name`, replacing any source already
-- registered under it.
--
-- `resolve` is called as `resolve(window)` and answers a properties table or
-- nothing. Sources are applied from the lowest precedence to the highest, so a
-- higher one layers over a lower one and wins where both name a key. Two at the
-- same precedence apply in registration order.
--
-- Replacing rather than appending is what makes a module safe to `require`
-- twice, and what lets a configuration re-register its rules after editing them
-- without accumulating copies of the old ones.
function rules.addSource(name, precedence, resolve)
  if type(name) ~= 'string' then
    error('mullion.rules: a source is named by a string, not a ' .. type(name), 2)
  end
  if type(precedence) ~= 'number' or precedence ~= precedence then
    error("mullion.rules: the precedence of '" .. name .. "' is an orderable number", 2)
  end
  if type(resolve) ~= 'function' then
    error("mullion.rules: the source '" .. name .. "' is not a function", 2)
  end

  rules.removeSource(name)
  registrations = registrations + 1
  sources[#sources + 1] = {
    name = name,
    precedence = precedence,
    resolve = resolve,
    sequence = registrations,
  }
end

-- Removes the source registered under `name`, reporting whether there was one.
function rules.removeSource(name)
  for index = 1, #sources do
    if sources[index].name == name then
      table.remove(sources, index)
      return true
    end
  end
  return false
end

-- The registered sources, in the order they are applied, as fresh tables.
--
-- Written so that a configuration can check the composition it declared rather
-- than infer it, and so that the specs can assert the order.
function rules.sources()
  local ordered = {}
  for index = 1, #sources do
    ordered[index] = sources[index]
  end
  table.sort(ordered, byPrecedence)

  local described = {}
  for index, source in ipairs(ordered) do
    described[index] = { name = source.name, precedence = source.precedence }
  end
  return described
end

-- Turns a flat ordered list of rules into a source function.
--
-- A rule is `{ match = { appId = 'firefox' }, properties = { width = 2 } }`. The
-- list is applied in order and a later match layers over an earlier one, so a
-- broad rule can set defaults and a narrow one override them.
--
-- The list is checked here rather than at the first window. A configuration with
-- a misspelt field should say so when it loads, not the first time the user
-- opens the application it was about.
function rules.fromList(list)
  if type(list) ~= 'table' then
    error('mullion.rules: a rules list is a table, not a ' .. type(list), 2)
  end

  local checked = {}
  for index = 1, #list do
    local rule = list[index]
    if type(rule) ~= 'table' then
      error('mullion.rules: rule ' .. index .. ' is a table, not a ' .. type(rule), 2)
    end
    if rule.match ~= nil and type(rule.match) ~= 'table' then
      error('mullion.rules: the match of rule ' .. index .. ' is a table, not a ' .. type(rule.match), 2)
    end
    if rule.properties ~= nil and type(rule.properties) ~= 'table' then
      error('mullion.rules: the properties of rule ' .. index .. ' are a table, not a ' .. type(rule.properties), 2)
    end
    checked[index] = { match = rule.match, properties = rule.properties }
  end

  return function(window)
    local collected = nil
    for _, rule in ipairs(checked) do
      if rule.properties and rules.matches(rule.match, window) then
        collected = layer(collected or {}, rule.properties)
      end
    end
    return collected
  end
end

-- Registers `list` as the configuration's own rules source.
--
-- The one-line form, and what a configuration that wants nothing but an `appId`
-- table calls. `addSource` is for anything else.
function rules.setRules(list)
  rules.addSource(rules.DEFAULT_SOURCE, rules.DEFAULT_PRECEDENCE, rules.fromList(list))
end

-- Whether `match` describes `window`.
--
-- Each key is compared against the window's field of that name. A value that is
-- a function is a predicate, called as `predicate(value, window)`, so a rule can
-- match a title by pattern without this module growing a pattern language.
--
-- A field the window does not carry does not match, and does not raise. A rule
-- naming `appId` is asked about every window, including one whose client never
-- set one, and that is an ordinary window rather than a defect.
--
-- An absent or empty match matches every window, which is what a source setting
-- defaults for everything wants to say.
--
-- A window is userdata as well as a table: `lunette.windows()` and
-- `event.window` answer a native handle, and a table is what a source
-- constructed for itself or what a spec minted. The guard is on being indexable,
-- not on being a table, and it exists so that `matches(match, 'firefox')` says
-- what is wrong rather than raising from inside the loop.
function rules.matches(match, window)
  if match == nil then
    return true
  end
  local kind = type(window)
  if kind ~= 'table' and kind ~= 'userdata' then
    error('mullion.rules: a window is a handle or a table, not a ' .. kind, 2)
  end

  for key, expected in pairs(match) do
    local actual = window[key]
    if type(expected) == 'function' then
      if not expected(actual, window) then
        return false
      end
    elseif actual ~= expected then
      return false
    end
  end
  return true
end

-- What every source says about `window`, layered in precedence order.
--
-- Function-valued properties are called as `value(window, key)` and replaced by
-- what they answer. That is what lets a rule say "the current tag" rather than
-- baking in whichever tag was current when the configuration loaded.
--
-- Only the surviving value of a key is called. A function a later source
-- overwrote is never evaluated, so a rule that spawns something or reads
-- something expensive does neither when it lost.
--
-- A caller wanting a property whose value is genuinely a function wraps it in
-- one that returns it.
function rules.resolve(window)
  local ordered = {}
  for index = 1, #sources do
    ordered[index] = sources[index]
  end
  table.sort(ordered, byPrecedence)

  local collected = {}
  for _, source in ipairs(ordered) do
    local answered = source.resolve(window)
    if answered ~= nil then
      if type(answered) ~= 'table' then
        error("mullion.rules: the source '" .. source.name .. "' answered a " .. type(answered) .. ', not a table')
      end
      layer(collected, answered)
    end
  end

  return evaluate(collected, window)
end

-- Creates the panel the rules describe for `window`, and returns it with the
-- properties it was made from.
--
-- This is what makes a rule matching `appId` place a newly spawned window
-- without further scripting: a configuration's `lovr.lunwindowopened` calls
-- this and writes nothing per window.
--
-- `options` is merged under the resolved properties, so a caller can supply
-- defaults a rule may override. Every key `PANEL_PROPERTIES` names goes to the
-- panel; `tags` names the tags the panel joins, by name or by tag; and
-- everything else is left in the returned table for the caller.
--
-- A tag named by a rule and not yet declared is created rather than refused, and
-- reported. A rule saying "this application lives on 'web'" is describing a
-- workspace, and refusing the window because the workspace has not been declared
-- yet would lose the window over a declaration order; a misspelt name reaches the
-- same path, so the creation is said out loud rather than assumed deliberate.
function rules.place(window, options)
  if window == nil then
    error('mullion.rules: a window is placed, and nil is not one', 2)
  end

  local properties = rules.resolve(window)
  if options then
    for key, value in pairs(options) do
      if properties[key] == nil then
        properties[key] = value
      end
    end
  end

  local panelOptions = {}
  for _, key in ipairs(rules.PANEL_PROPERTIES) do
    panelOptions[key] = properties[key]
  end
  panelOptions.pose = poseFrom(properties.pose, window)

  local created = panel.fromWindow(window, panelOptions)
  applyTags(created, properties.tags)
  return created, properties
end

-- Discards every source.
--
-- Registered as this module's teardown hook, so that a soft reload does not
-- leave the old configuration's rules composing with the new one's.
function rules.teardown()
  sources = {}
  registrations = 0
end

-- Orders sources from the lowest precedence to the highest, and by registration
-- order within one.
--
-- Registration order rather than nothing, so that two sources at the same
-- precedence apply in a stated order rather than in whichever one `table.sort`
-- happened to produce for that many entries.
function byPrecedence(left: Source, right: Source)
  if left.precedence ~= right.precedence then
    return left.precedence < right.precedence
  end
  return left.sequence < right.sequence
end

-- Copies `applied` over `collected`, in place, and returns it.
function layer(collected, applied)
  for key, value in pairs(applied) do
    collected[key] = value
  end
  return collected
end

-- Calls every function-valued property and returns a fresh table of the answers.
function evaluate(collected, window)
  local evaluated = {}
  for key, value in pairs(collected) do
    if type(value) == 'function' then
      evaluated[key] = value(window, key)
    else
      evaluated[key] = value
    end
  end
  return evaluated
end

-- Adds `created` to each of `tags`, which are names or tag objects.
function applyTags(created, tags)
  if tags == nil then
    return
  end
  if type(tags) ~= 'table' then
    rules.report('tags are an array of names or tags, not a ' .. type(tags))
    return
  end

  for _, named in ipairs(tags) do
    if tag.isTag(named) then
      named:add(created)
    elseif type(named) == 'string' then
      -- Created rather than refused, per `place`'s note: losing the window over
      -- a declaration order is worse than a tag nothing declared. Reported all
      -- the same, because the other way to arrive here is a misspelt name, and
      -- an unreported one is a workspace nobody asked for holding a window
      -- nobody can find.
      local found = tag.find(named)
      if not found then
        found = tag.new(named)
        rules.report("nothing declared the tag '" .. named .. "', so it was created", 'info')
      end
      found:add(created)
    else
      rules.report('a tag is named by a string or is a tag, not a ' .. type(named))
    end
  end
end

-- A property's pose as a `Mat4`, or nothing.
--
-- A string is what `mullion.pose` writes, which is what the property store and a
-- saved arrangement both hold, so a source reading either can hand its value
-- straight through. A string that is not sixteen numbers is reported rather than
-- placing the panel at the origin, where a window silently arriving at the
-- user's feet would be diagnosed as a layout defect.
function poseFrom(value, window)
  if type(value) ~= 'string' then
    return value
  end

  local decoded = pose.decode(value)
  if not decoded then
    rules.report("the pose for '" .. tostring(window.appId) .. "' is not sixteen numbers, so it is ignored")
  end
  return decoded
end

-- Registered by name, so that a module body running a second time — which is
-- what a soft reload does — leaves one hook rather than two.
teardown.register('mullion.rules', rules.teardown)

return rules

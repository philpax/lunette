-- Rules: what a window should look like, decided before anything draws it.
--
-- docs/stdlib.md's tier 3, the part that decides where a window goes. The
-- minimum-viable line asks for a rules table matched on `appId`, and this is it,
-- plus the composition that saved arrangements need to sit alongside it rather
-- than inside it.
--
-- The shape is awesome's and none of its code: awesome is GPL-2 and lunette
-- GPL-3-only (CREDITS.md), so nothing was copied and its source was not
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
-- the configuration (docs/stdlib.md), so `lunette.onWindowOpened` calls `place`
-- rather than this module taking the callback out from under it.

local lunette = require '@lunette'

local panel = require '@mullion/panel'
local pose = require '@mullion/pose'
local tag = require '@mullion/tag'
local teardown = require '@mullion/teardown'

local rules = {}

local byPrecedence, layer, evaluate, applyTags, poseFrom

-- Every source, as `{ { name, precedence, resolve, sequence } }` in registration
-- order.
--
-- Rebuilt when this file runs, so a soft reload that re-runs the configuration
-- starts from no sources rather than from the old state's.
-- A property's value, or a function answering one when the rule is applied.
--
-- The function form is called as `value(window, key)` and is what lets a rule
-- say "the current tag" rather than baking in whichever tag was current when the
-- configuration loaded.
export type Valued<T> = T | ((window: lunette.Window, key: string) -> T)

-- What a source says about a window: the keys `place` acts on, and whatever else
-- the configuration wants to carry.
--
-- The named fields are `read`, so that an evaluated table answers a declared
-- one: Luau compares a read-write property invariantly, and `pose: string?`
-- would not otherwise satisfy `pose: Valued<string | Mat4>?`.
--
-- What that does not buy is a check on writing one. An open indexer answers a
-- write to a named key as well, so `properties.width = 'wide'` is accepted
-- where the same table built as a literal is not. The types are enforced where
-- a configuration writes them — a rules table, a source's return — and not
-- against this module's own assignments, which go through the indexer anyway.
--
-- The indexer is what keeps it an open bag. A rule setting a key this module has
-- never heard of is a configuration talking to itself, and it arrives back in
-- `place`'s second return untouched; the named keys are the ones that go
-- somewhere, so those are the ones typed.
export type Properties = {
  read pose: Valued<string | Mat4>?,
  read width: Valued<number>?,
  read height: Valued<number>?,
  read title: Valued<string>?,
  read priority: Valued<number>?,
  read chrome: Valued<boolean>?,
  -- A read-only element type, so that a source answering plain names satisfies
  -- it: a type argument is compared exactly otherwise.
  read tags: Valued<{ read [number]: string | Tag }>?,
  [string]: any,
}

-- The same after `resolve` has called every function-valued property: what a
-- rule meant, rather than how it said it. `place`'s second return is one, and so
-- is its `options`, which are merged after the evaluation and are therefore
-- taken as written.
export type Resolved = {
  read pose: (string | Mat4)?,
  read width: number?,
  read height: number?,
  read title: string?,
  read priority: number?,
  read chrome: boolean?,
  read tags: { read [number]: string | Tag }?,
  [string]: any,
}
-- What a rule matches on. The keys are the window's own field names, so a rule
-- naming a field a window has not got is a type error where it is written
-- rather than a rule that silently never fires. A value is compared for
-- equality, or called as a predicate.
export type Match = { [MatchKey]: any }

-- The fields a rule may name. `keyof<lunette.Window>` would be this and the
-- window's methods as well, and a rule matching on `close` is one that silently
-- never fires.
type MatchKey = 'dead' | 'id' | 'title' | 'appId' | 'width' | 'height' | 'opaque' | 'contentType'
type Rule = {
  match: Match?,
  properties: Properties?,
}

-- A tag, or the name of one, as `tags` names them.
type Tag = tag.Tag

type Source = {
  name: string,
  precedence: number,
  resolve: (window: lunette.Window) -> Properties?,
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
-- Replaceable, so that the host's error handling can route it with everything
-- else, and so that a spec can capture it rather than printing it.
-- The default logs the message, which the host routes to its own diagnostics.
--
-- `level` carries a LÖVR log level and defaults to `warn`, because most of what
-- reaches here is a rule the configuration wrote that could not be honoured. A
-- tag created on demand is the exception: that is the documented behaviour
-- rather than a mistake, so it reports at `info`.
function rules.report(message: string, level: string?)
  local log = lovr.log
  if log then
    log(message, level or 'warn', 'mullion.rules')
  end
end

-- Registers `resolve` as a source under `name`, replacing any source already
-- registered under it.
--
-- `resolve` is called as `resolve(window)` and answers a properties table or
-- nothing. Sources are applied from the lowest precedence to the highest, so a
-- higher one layers over a lower one and wins where both name a key. Two at the
-- same precedence apply in registration order.
--
-- Replacing rather than appending makes repeated `require` calls safe and lets a
-- configuration re-register edited rules without accumulating old copies.
function rules.addSource(name: string, precedence: number, resolve: (window: lunette.Window) -> Properties?)
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
function rules.fromList(list: { Rule }): (window: lunette.Window) -> Properties?
  if type(list) ~= 'table' then
    error('mullion.rules: a rules list is a table, not a ' .. type(list), 2)
  end

  local checked: { Rule } = {}
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
function rules.setRules(list: { Rule })
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
function rules.matches(match: Match?, window: lunette.Window): boolean
  if match == nil then
    return true
  end
  local kind = type(window)
  if kind ~= 'table' and kind ~= 'userdata' then
    error('mullion.rules: a window is a handle or a table, not a ' .. kind, 2)
  end

  -- The one reflective read in this module: the field's name arrives from a
  -- rule at runtime, and no type describes indexing a handle by a name held in
  -- a variable. `keyof` above is what makes sure the name is one a window has.
  local fields: { [string]: any } = window :: any
  for key, expected in pairs(match :: { [string]: any }) do
    local actual = fields[key]
    if type(expected) == 'function' then
      local predicate: (any, any) -> boolean = expected
      if not predicate(actual, window) then
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
function rules.resolve(window: lunette.Window): Resolved
  local ordered: { Source } = {}
  for index = 1, #sources do
    ordered[index] = sources[index]
  end
  table.sort(ordered, byPrecedence)

  local collected: Properties = {}
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
-- without further scripting: a configuration's `lunette.onWindowOpened` calls
-- this and writes nothing per window.
--
-- `options` is merged under the resolved properties, so a caller can supply
-- defaults a rule may override. Every key `PANEL_PROPERTIES` names goes to the
-- panel; `tags` names the tags the panel joins, by name or by tag; and
-- everything else is left in the returned table for the caller.
--
-- A tag named by a rule and not yet declared is created rather than refused, and
-- reported. A rule saying "this application lives on 'web'" describes a workspace;
-- a misspelt name reaches the same path, so the creation is said out loud rather
-- than assumed deliberate.
function rules.place(window: lunette.Window, options: Resolved?): (panel.Panel, Resolved)
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

  -- Named rather than walked over `PANEL_PROPERTIES`, so that each one is
  -- checked against what a panel takes. The constant is what documents the set.
  local created = panel.fromWindow(window, {
    pose = poseFrom(properties.pose, window),
    width = properties.width,
    height = properties.height,
    title = properties.title,
    priority = properties.priority,
    chrome = properties.chrome,
  })
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
function layer(collected: Properties, applied: Properties): Properties
  for key, value in pairs(applied) do
    collected[key] = value
  end
  return collected
end

-- Calls every function-valued property and returns a fresh table of the answers.
function evaluate(collected: Properties, window: lunette.Window): Resolved
  local evaluated: Resolved = {}
  for key, value in pairs(collected) do
    if type(value) == 'function' then
      local evaluator: (any, string) -> any = value
      evaluated[key] = evaluator(window, key)
    else
      evaluated[key] = value
    end
  end
  return evaluated
end

-- Adds `created` to each of `tags`, which are names or tag objects.
function applyTags(created: panel.Panel, tags: { read [number]: string | tag.Tag }?)
  if tags == nil then
    return
  end
  if type(tags) ~= 'table' then
    rules.report('tags are an array of names or tags, not a ' .. type(tags))
    return
  end

  for index = 1, #tags do
    local named = tags[index]
    if tag.isTag(named) and type(named) == 'table' then
      named:add(created)
    elseif type(named) == 'string' then
      -- A missing tag is created rather than refused, as described by `place`.
      -- Report it because the same path handles a misspelt name.
      local found = tag.find(named)
      if not found then
        found = tag.new(named, nil)
        rules.report("nothing declared the tag '" .. named .. "', so it was created", 'info')
      end
      if found then
        found:add(created)
      end
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
function poseFrom(value: string | Mat4?, window: lunette.Window): Mat4?
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

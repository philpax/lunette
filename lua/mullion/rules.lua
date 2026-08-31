-- Rules: what a window should look like, decided ahead of drawing.
--
-- docs/dev/stdlib.md's tier 3: the module that implements window placement. The
-- minimum-viable line requires a rules table matched on `appId`. This module
-- provides that table, and a saved arrangement composes as a separate source
-- beside it.
--
-- The design is awesome's and none of its code. awesome is GPL-2 and lunette
-- is GPL-3-only (CREDITS.md). No code is copied, and the source is not
-- consulted. A design is not copyrightable, and the design taken from awesome
-- is a flat ordered list of match-and-properties tables and a matcher that
-- composes several sources with a declared precedence.
--
-- Restore-on-startup and apply-rules-on-open address the same window with
-- different outcomes: a hand-placed window returns to its saved position, and
-- a fresh window opens where the rules place it. One list makes one of those
-- outcomes wrong; which one depends on the order the configuration writes its
-- entries in. As separate sources, the precedence the configuration assigns
-- selects between them.
--
-- This module takes no `lovr.lun*` callback. The callback namespace belongs
-- to the configuration (docs/dev/stdlib.md). `lunette.onWindowOpened` calls
-- `place`.

local lunette = require '@lunette'

local panel = require '@mullion/panel'
local pose = require '@mullion/pose'
local tag = require '@mullion/tag'
local teardown = require '@mullion/teardown'

local rules = {}

-- These names are declared here and defined below the public API, so the
-- public API appears first in the file.
local byPrecedence, layer, evaluate, applyTags, poseFrom

-- Every source, as `{ { name, precedence, resolve, sequence } }` in registration
-- order.
--
-- Rebuilt when the module body runs. A soft reload re-runs the configuration
-- and starts from no sources; the old list is discarded.
-- A property's value, or a function answering one when the rule is applied.
--
-- The function form is called as `value(window, key)` when the rule applies.
-- A rule uses it to name the current tag at apply time, not the tag current at
-- configuration load.
export type Valued<T> = T | ((window: lunette.Window, key: string) -> T)

-- What a source provides about a window: the keys `place` acts on, and whatever
-- else the configuration carries.
--
-- The named fields are `read`, so an evaluated table satisfies the declared
-- type. Luau compares a read-write property invariantly, and `pose: string?`
-- would not otherwise satisfy `pose: Valued<string | Mat4>?`.
--
-- That does not check writes. An open indexer answers a write to a named key
-- as well, so `properties.width = 'wide'` is accepted where the same table
-- built as a literal is not. The types are enforced where a configuration
-- writes them, at a rules table or a source's return; this module's own
-- assignments go through the indexer.
--
-- The indexer keeps the type open. A key this module does not name arrives
-- back in `place`'s second return, untouched; the named keys are the ones the
-- panel uses, so those are the ones typed.
export type Properties = {
  read pose: Valued<string | Mat4>?,
  read width: Valued<number>?,
  read height: Valued<number>?,
  read title: Valued<string>?,
  read priority: Valued<number>?,
  read chrome: Valued<boolean>?,
  -- A read-only element type, so a source answering plain names satisfies it.
  -- A type argument is compared exactly otherwise.
  read tags: Valued<{ read [number]: string | Tag }>?,
  [string]: any,
}

-- The same after `resolve` has called every function-valued property: plain
-- values, no functions. `place`'s second return is one, and so is its
-- `options`, which merge after evaluation and are taken as written.
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
-- naming a field a window does not have is a type error where the rule is
-- written. A value is compared for equality, or called as a predicate.
export type Match = { [MatchKey]: any }

-- The fields a rule may name. `keyof<lunette.Window>` would also name the
-- window's methods, and a rule matching on `close` would never fire.
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

-- The count of all registrations; the tiebreak between two sources at the
-- same precedence.
local registrations = 0

-- Where `setRules` registers the configuration's own rules table.
--
-- A round number with room on either side, so a source can take a lower or
-- higher precedence than the configuration's rules table without renumbering.
rules.DEFAULT_PRECEDENCE = 100

-- The name `setRules` registers under.
rules.DEFAULT_SOURCE = 'mullion.rules'

-- The panel options `place` takes out of a resolved property table.
--
-- Everything else in the table is returned to the caller untouched. A
-- properties table may carry any keys; a key the module does not name carries
-- the configuration's own data.
rules.PANEL_PROPERTIES = { 'pose', 'width', 'height', 'title', 'priority', 'chrome' }

-- Where a rule that could not be honoured is reported.
--
-- Replaceable, so error handling can route it anywhere, and so a spec can
-- capture it. The default logs the message, which the host routes to its own
-- diagnostics.
--
-- `level` carries a LÖVR log level and defaults to `warn`; most of what
-- reaches here is a rule the configuration wrote that could not be honoured. A
-- tag created on demand is the exception: its report uses `info`, and the
-- creation is documented behaviour.
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
-- nothing. Sources apply from the lowest precedence to the highest; a higher
-- one layers over a lower one, and where both name a key the higher one's
-- value applies. Two at the same precedence apply in registration order.
--
-- Replacing an existing registration under the same name makes a module safe
-- to `require` twice. A configuration can re-register its rules after editing
-- them without accumulating copies of the old ones.
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

-- Removes the source registered under `name`, and reports whether it removed
-- a source.
function rules.removeSource(name)
  for index = 1, #sources do
    if sources[index].name == name then
      table.remove(sources, index)
      return true
    end
  end
  return false
end

-- The registered sources, in application order, as fresh tables.
--
-- Written so a configuration can check the composition it declared, and so the
-- specs can assert the order.
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
-- list applies in order and a later match layers over an earlier one, so a
-- broad rule can set defaults and a narrow one override them.
--
-- The list is checked when the source is built, not at the first window. A
-- configuration with a misspelt field reports when it loads, not when the user
-- first opens the application the rule targets.
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
-- The one-line form: a configuration matching on `appId` calls this.
-- `addSource` is for anything else.
function rules.setRules(list: { Rule })
  rules.addSource(rules.DEFAULT_SOURCE, rules.DEFAULT_PRECEDENCE, rules.fromList(list))
end

-- Whether `match` describes `window`.
--
-- Each key is compared against the window's field of that name. A value that is
-- a function is a predicate, called as `predicate(value, window)`, so a rule can
-- match a title by pattern without this module implementing a pattern language.
--
-- A field the window does not carry does not match and does not raise. A match
-- on `appId` is evaluated for every window, including one whose client never
-- set an `appId`.
--
-- An absent or empty match matches every window. Sources setting defaults for
-- everything use that form.
--
-- A window is userdata as well as a table: `lunette.windows()` and
-- `event.window` answer a native handle, and a table is what a source
-- constructed for itself or what a spec created. The guard tests indexability,
-- not table type; `matches(match, 'firefox')` reports what is wrong, and the
-- loop never raises on a non-table argument.
function rules.matches(match: Match?, window: lunette.Window): boolean
  if match == nil then
    return true
  end
  local kind = type(window)
  if kind ~= 'table' and kind ~= 'userdata' then
    error('mullion.rules: a window is a handle or a table, not a ' .. kind, 2)
  end

  -- The module's one reflective read: the field's name arrives from a rule at
  -- runtime, and no type describes indexing a handle by a variable-held name.
  -- The `MatchKey` union restricts the name to one a window has.
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

-- What every source contributes for `window`, layered in precedence order.
--
-- Function-valued properties are called as `value(window, key)` and replaced by
-- what they answer. A rule uses that form to name the current tag at apply
-- time, not the tag current at configuration load.
--
-- The surviving value of a key is called; the values overwritten by a later
-- source are never called. A rule that spawns something or reads something
-- expensive triggers neither effect when a later source overrides its key.
--
-- To store a function as the property's value, wrap the function in a function
-- that returns it.
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

-- Creates the panel the rules describe for `window`, and returns the panel
-- together with the resolved properties.
--
-- `place` places a newly spawned window from a rule matching `appId`, with no
-- further scripting: a configuration's `lunette.onWindowOpened` calls `place`
-- and writes nothing per window.
--
-- `options` merges under the resolved properties, so a caller can supply
-- defaults a rule may override. Every key `PANEL_PROPERTIES` names goes to the
-- panel; `tags` names the tags the panel joins, by name or by tag; and
-- everything else is left in the returned table for the caller.
--
-- A tag named by a rule and not yet declared is created and reported. A
-- rule naming 'web' as a tag describes a workspace; refusing the window
-- because the workspace is undeclared would lose the window over a declaration
-- order. A misspelt name reaches the same path, so the creation is always
-- reported; a silent creation would conceal a misspelling.
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

  -- Named, not walked over `PANEL_PROPERTIES`, so each one is checked against
  -- what a panel takes. The constant documents the set.
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
-- Registered as this module's teardown hook, so a soft reload does not leave
-- the old configuration's rules composing with the new one's rules.
function rules.teardown()
  sources = {}
  registrations = 0
end

-- Orders sources from the lowest precedence to the highest, and by registration
-- order within one.
--
-- Registration order is the secondary key, so two sources at the same
-- precedence apply in a stated order. `table.sort` permits any order for equal
-- entries.
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
      -- Per `place`'s note, a tag is created when nothing declared it: losing
      -- the window over a declaration order is worse than carrying a tag
      -- nothing declared. The creation is still reported, because a misspelt
      -- name is the other way this path is reached. Unreported, the tag is a
      -- workspace no configuration declared, holding a window no one can find.
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
-- `mullion.pose` writes a string as a pose; the property store and a saved
-- arrangement both hold that form, so a source reading either can pass its
-- value straight through. A string that is not sixteen numbers is reported.
-- Placing the panel at the origin would put a window at the user's feet and
-- read as a layout defect.
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

-- Registered by name, so a module body running a second time, as a soft reload
-- does, leaves a single hook.
teardown.register('mullion.rules', rules.teardown)

return rules

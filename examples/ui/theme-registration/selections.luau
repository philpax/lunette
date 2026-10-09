-- Manual selection ranking, immutable snapshots, and reentrant listener delivery.
local plugin = require '@lunette-plugin'
local theme = require '@lunette-contracts/theme'
local session = require './session'

local selections = {}

function selections.install(demo: session.Session): ()
  local themes = demo.themes
  local a, b: theme.Registration? = nil, nil
  local aOwner, bOwner: plugin.Context? = nil, nil
  local aChild, bChild: session.Child? = nil, nil
  local prior, retained: theme.Snapshot? = nil, nil
  local source = { colors = { background = { 0.12, 0.04, 0.07, 1 } } }
  local a2: theme.ThemeOverrides = { colors = { background = { 0.04, 0.18, 0.08, 1 } } }
  local bStyle: theme.ThemeOverrides = { colors = { background = { 0.04, 0.08, 0.24, 1 } } }
  local aLive, bLive = false, false
  local function requireB(): theme.Registration
    assert(bLive, 'Select A then B first')
    return assert(b)
  end
  local function disposeSelections(): ()
    if b then
      b:dispose()
    end
    if a then
      a:dispose()
    end
    if bChild and bChild.instance:state() ~= 'removed' then
      bChild.instance:dispose()
    end
    if aChild and aChild.instance:state() ~= 'removed' then
      aChild.instance:dispose()
    end
    aLive, bLive = false, false
  end
  local function invalid(id: string, label: string, value: theme.ThemeOverrides): ()
    local before: theme.Snapshot? = nil
    local ranking = ''
    demo.action(id, label, function(): ()
      local registration = requireB()
      before = themes:current()
      local fields: { string } = {}
      for _, entry in themes:inspect().registrations do
        if entry.owner == bOwner then
          table.insert(fields, demo.metadata(entry.details))
        end
      end
      ranking = table.concat(fields, ';')
      registration:update(value)
      error('theme registration example: invalid B update unexpectedly succeeds', 0)
    end, function(): ()
      if not before then
        return
      end
      demo.check(themes:current() == before, 'Invalid B update preserves the live snapshot and revision')
      local fields: { string } = {}
      for _, entry in themes:inspect().registrations do
        if entry.owner == bOwner then
          table.insert(fields, demo.metadata(entry.details))
        end
      end
      demo.check(table.concat(fields, ';') == ranking, 'Invalid B update preserves rank and font metadata')
    end)
  end

  demo.action('select-a', '1. Select A', function(): ()
    disposeSelections()
    prior = themes:current()
    source.colors.background = { 0.12, 0.04, 0.07, 1 }
    aChild = demo.child('selection-A', function(owner: plugin.Context): ()
      aOwner = owner
      a = themes:select(owner, source)
      aLive = true
    end)
    retained = themes:current()
    demo.check(retained.theme.colors.background[1] == 0.12, 'A supplies its distinct background')
    demo.check(
      table.isfrozen(retained) and table.isfrozen(retained.theme) and table.isfrozen(retained.theme.colors.background),
      'Snapshot and nested style are frozen'
    )
  end)
  demo.action('mutate-input', '2. Mutate A input', function(): ()
    assert(aLive and retained, 'Select A first')
    source.colors.background[1] = 0.9
    source.colors.background = { 0.9, 0.9, 0.9, 1 }
    demo.check(retained.theme.colors.background[1] == 0.12, 'Retained snapshot is detached from input mutation')
    demo.check(themes:current() == retained, 'Caller mutation changes neither current theme nor revision')
  end)
  demo.action('write-snapshot', '3. Write frozen snapshot (error)', function(): ()
    local snapshot = assert(retained, 'Select A first')
    local writable = (snapshot.theme.colors.background :: unknown) :: { number }
    writable[1] = 0.8
    error('theme registration example: frozen write unexpectedly succeeds', 0)
  end, function(): ()
    if retained then
      demo.check(retained.theme.colors.background[1] == 0.12, 'Frozen write preserves retained A')
    end
  end)
  demo.action('select-b', '4. Select B', function(): ()
    assert(aLive and not bLive, 'Select A first; dispose B before replacing it')
    bChild = demo.child('selection-B', function(owner: plugin.Context): ()
      bOwner = owner
      b = themes:select(owner, bStyle)
      bLive = true
    end)
    demo.check(themes:current().theme.colors.background[3] == 0.24, 'B wins with its distinct background')
  end)
  demo.action('update-a', '5. Update inactive A to A2', function(): ()
    requireB()
    local before = themes:current()
    assert(a):update(a2)
    demo.check(themes:current() == before, 'Inactive A update does not publish or change B')
    local rankA, rankB = 0, 0
    for _, entry in themes:inspect().registrations do
      local rank = entry.details.rank
      if entry.kind == 'selection' and type(rank) == 'number' then
        if entry.owner == aOwner then
          rankA = rank
        end
        if entry.owner == bOwner then
          rankB = rank
        end
      end
    end
    demo.check(rankA > 0 and rankB > rankA, 'Update preserves selection insertion rank')
  end)
  -- Unknown fields intentionally cross the typed boundary to demonstrate runtime validation.
  invalid(
    'invalid-unknown',
    '6. Unknown B key (error)',
    ({ colors = { background = { 0.5, 0.5, 0.5, 1 } }, unknown = true } :: unknown) :: theme.ThemeOverrides
  )
  invalid('invalid-color', '7. Invalid B color (error)', { colors = { background = { 1, 2, 0, 1 } } })
  invalid('invalid-font', '8. Missing B font (error)', {
    typography = { font = { kind = 'file', file = 'theme-registration-missing-font.ttf', size = 32, spread = 4 } },
  })
  demo.action('dispose-b', '9. Dispose B; reveal A2', function(): ()
    requireB():dispose()
    bLive = false
    demo.check(themes:current().theme.colors.background[2] == 0.18, 'Disposing B reveals updated A2')
  end)
  demo.action('dispose-a', '10. Dispose A; restore prior/base', function(): ()
    assert(aLive, 'Select A first')
    assert(not bLive, 'Dispose B first')
    assert(a):dispose()
    aLive = false
    demo.check(
      themes:current().theme == assert(prior).theme,
      'Last demo selection restores the preceding theme or base'
    )
  end)
  demo.action('dispose-again', '11. Repeat dispose; end A/B owners', function(): ()
    assert(a and b and not aLive and not bLive, 'Dispose A and B first')
    local before = themes:current()
    disposeSelections()
    demo.check(themes:current() == before, 'Repeated disposal and owner teardown are idempotent')
  end)
  local disposedBefore: theme.Snapshot? = nil
  demo.action('disposed-update', '12. Update disposed B (error)', function(): ()
    assert(not bLive and b, 'Dispose B first')
    disposedBefore = themes:current()
    b:update(bStyle)
    error('theme registration example: disposed update unexpectedly succeeds', 0)
  end, function(): ()
    if disposedBefore then
      demo.check(themes:current() == disposedBefore, 'Disposed update preserves theme and revision')
    end
  end)

  local listenerChildren: { session.Child } = {}
  local listenerSelection: theme.Registration? = nil
  local listenerPrior: theme.Snapshot? = nil
  local insideMutation = false
  local armed, fired = false, false
  local l2: plugin.Effect? = nil
  local firstRevision = 0
  local deliveries: { [string]: { number } } = {}
  local function disarm(): ()
    armed = false
    for _, child in listenerChildren do
      child.instance:dispose()
    end
    table.clear(listenerChildren)
  end
  local function listen(name: string, run: (theme.Snapshot) -> ()): ()
    local child = demo.child('listener-' .. name, function(owner: plugin.Context): ()
      local effect = themes:onChanged(owner, run)
      if name == 'L2' then
        l2 = effect
      end
    end)
    table.insert(listenerChildren, child)
  end
  local function record(name: string, event: theme.Snapshot): ()
    assert(not insideMutation, 'theme registration example: listener delivery reenters the mutator')
    local revisions = deliveries[name]
    if not revisions then
      revisions = {}
      deliveries[name] = revisions
    end
    table.insert(revisions, event.revision)
    demo.log(name .. ' event=' .. tostring(event.revision) .. ' current=' .. tostring(themes:current().revision))
  end
  demo.action('arm-listeners', '13. Arm one-shot reentrant listeners', function(): ()
    disarm()
    disposeSelections()
    listenerPrior = themes:current()
    local child = demo.child('listener-selection', function(owner: plugin.Context): ()
      listenerSelection = themes:select(owner, bStyle)
    end)
    table.insert(listenerChildren, child)
    table.clear(deliveries)
    fired, armed = false, true
    listen('L1', function(event: theme.Snapshot): ()
      record('L1', event)
      if not armed or fired then
        return
      end
      fired = true
      firstRevision = event.revision
      assert(l2):dispose()
      demo.log 'L1 removes L2 and adds L4; new L4 misses this captured round'
      listen('L4', function(value: theme.Snapshot): ()
        record('L4', value)
      end)
      insideMutation = true
      assert(listenerSelection):update { colors = { background = { 0.18, 0.04, 0.12, 1 } } }
      assert(listenerSelection):update { colors = { background = { 0.08, 0.12, 0.22, 1 } } }
      local temporary = demo.child('temporary-selection', function(owner: plugin.Context): ()
        themes:select(owner, { colors = { background = { 0.22, 0.15, 0.04, 1 } } })
      end)
      temporary.instance:dispose()
      insideMutation = false
      demo.log 'L1 ends temporary owner; queued changes coalesce into the latest revision'
      error('theme registration example: L1 deliberate listener error', 0)
    end)
    listen('L2', function(event: theme.Snapshot): ()
      record('L2', event)
    end)
    listen('L3', function(event: theme.Snapshot): ()
      record('L3', event)
    end)
  end)
  demo.action('trigger-listeners', '14. Trigger L1 (listener error)', function(): ()
    assert(armed and not fired, 'Arm the one-shot listeners first')
    assert(listenerSelection):update { colors = { background = { 0.14, 0.06, 0.21, 1 } } }
    local third, fourth = assert(deliveries.L3), assert(deliveries.L4)
    demo.check(not insideMutation, 'Reentrant changes deliver nonrecursively after the mutator returns')
    demo.check(deliveries.L2 == nil, 'Removed L2 receives no callback')
    demo.check(third[1] == firstRevision, 'Independent L3 receives the original captured event despite L1 error')
    demo.check(
      #third == 2 and third[2] == themes:current().revision,
      'Multiple changes coalesce into one later delivery'
    )
    demo.check(#fourth == 1 and fourth[1] == third[2], 'Added L4 joins only the later captured round')
    demo.check(third[2] > third[1] + 1, 'Delivered revisions expose coalescing rather than every intermediate change')
  end)
  demo.action('disarm-listeners', '15. Disarm listeners', function(): ()
    disarm()
    if listenerPrior then
      demo.check(themes:current().theme == listenerPrior.theme, 'Listener selection teardown restores prior/base')
    end
    local summaries: { string } = {}
    for _, name in { 'L1', 'L2', 'L3', 'L4' } do
      local revisions: { string } = {}
      for _, revision in deliveries[name] or {} do
        table.insert(revisions, tostring(revision))
      end
      table.insert(summaries, name .. '=[' .. table.concat(revisions, ',') .. ']')
    end
    demo.log(table.concat(summaries, ' ') .. ' current=' .. tostring(themes:current().revision))
    demo.log 'L1/L2/L3/L4 owners end; mutator is disarmed before further actions'
  end)
end

return selections
